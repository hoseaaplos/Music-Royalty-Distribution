;; contracts/music-royalty-platform.clar

;; Music Royalty Distribution Platform
;; Enables artists to tokenize music rights and automatically distribute royalties

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-percentage (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-insufficient-funds (err u105))
(define-constant err-invalid-split (err u106))

;; Data Variables
(define-data-var next-song-id uint u1)
(define-data-var platform-fee-percentage uint u250) ;; 2.5% in basis points

;; Data Maps
(define-map songs uint {
    artist: principal,
    title: (string-ascii 100),
    total-shares: uint,
    total-revenue: uint,
    created-at: uint
})

(define-map song-splits { song-id: uint, stakeholder: principal } {
    shares: uint,
    percentage: uint ;; in basis points (100 = 1%)
})

(define-map stakeholder-balances { song-id: uint, stakeholder: principal } uint)

(define-map streaming-integrations uint {
    platform-name: (string-ascii 50),
    api-key-hash: (buff 32),
    active: bool
})

;; Read-only functions
(define-read-only (get-song (song-id uint))
    (map-get? songs song-id)
)

(define-read-only (get-song-split (song-id uint) (stakeholder principal))
    (map-get? song-splits { song-id: song-id, stakeholder: stakeholder })
)

(define-read-only (get-stakeholder-balance (song-id uint) (stakeholder principal))
    (default-to u0 (map-get? stakeholder-balances { song-id: song-id, stakeholder: stakeholder }))
)

(define-read-only (get-platform-fee-percentage)
    (var-get platform-fee-percentage)
)

(define-read-only (calculate-royalty-split (song-id uint) (revenue uint) (stakeholder principal))
    (match (get-song-split song-id stakeholder)
        split-data (/ (* revenue (get percentage split-data)) u10000)
        u0
    )
)

;; Public functions
(define-public (create-song (title (string-ascii 100)) (stakeholders (list 20 principal)) (percentages (list 20 uint)))
    (let (
        (song-id (var-get next-song-id))
        (total-percentage (fold + percentages u0))
    )
        (asserts! (is-eq (len stakeholders) (len percentages)) err-invalid-split)
        (asserts! (is-eq total-percentage u10000) err-invalid-percentage) ;; Must equal 100%

        ;; Create song record
        (map-set songs song-id {
            artist: tx-sender,
            title: title,
            total-shares: u10000,
            total-revenue: u0,
            created-at: stacks-block-height
        })

        ;; Set up splits
        (map set-song-splits
            (map make-split-entry stakeholders percentages)
            (list song-id)
        )

        (var-set next-song-id (+ song-id u1))
        (ok song-id)
    )
)

(define-private (make-split-entry (stakeholder principal) (percentage uint))
    { stakeholder: stakeholder, percentage: percentage }
)

(define-private (set-song-splits (split-data { stakeholder: principal, percentage: uint }) (song-id uint))
    (map-set song-splits
        { song-id: song-id, stakeholder: (get stakeholder split-data) }
        { shares: (get percentage split-data), percentage: (get percentage split-data) }
    )
)

(define-public (distribute-royalties (song-id uint) (revenue uint))
    (let (
        (song-data (unwrap! (get-song song-id) err-not-found))
        (platform-fee (/ (* revenue (var-get platform-fee-percentage)) u10000))
        (distributable-revenue (- revenue platform-fee))
    )
        ;; Only song artist or contract owner can distribute royalties
        (asserts! (or (is-eq tx-sender (get artist song-data))
                     (is-eq tx-sender contract-owner)) err-unauthorized)

        ;; Update total revenue
        (map-set songs song-id
            (merge song-data { total-revenue: (+ (get total-revenue song-data) revenue) }))

        ;; Distribute to all stakeholders would require iteration
        ;; For this implementation, we'll handle individual distributions
        (ok distributable-revenue)
    )
)

(define-public (claim-royalties (song-id uint))
    (let (
        (balance (get-stakeholder-balance song-id tx-sender))
    )
        (asserts! (> balance u0) err-insufficient-funds)

        ;; Reset balance
        (map-set stakeholder-balances
            { song-id: song-id, stakeholder: tx-sender } u0)

        ;; Transfer STX (simplified - in production would integrate with payment rails)
        (stx-transfer? balance tx-sender contract-owner)
    )
)

(define-public (add-streaming-integration (song-id uint) (platform-name (string-ascii 50)) (api-key-hash (buff 32)))
    (let (
        (song-data (unwrap! (get-song song-id) err-not-found))
    )
        (asserts! (is-eq tx-sender (get artist song-data)) err-unauthorized)

        (map-set streaming-integrations song-id {
            platform-name: platform-name,
            api-key-hash: api-key-hash,
            active: true
        })
        (ok true)
    )
)

(define-public (update-stakeholder-balance (song-id uint) (stakeholder principal) (amount uint))
    (let (
        (song-data (unwrap! (get-song song-id) err-not-found))
        (current-balance (get-stakeholder-balance song-id stakeholder))
    )
        ;; Only contract owner or song artist can update balances
        (asserts! (or (is-eq tx-sender contract-owner)
                     (is-eq tx-sender (get artist song-data))) err-unauthorized)

        (map-set stakeholder-balances
            { song-id: song-id, stakeholder: stakeholder }
            (+ current-balance amount))
        (ok true)
    )
)

;; Admin functions
(define-public (set-platform-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-fee u1000) err-invalid-percentage) ;; Max 10%
        (var-set platform-fee-percentage new-fee)
        (ok true)
    )
)

;; contracts/streaming-oracle.clar

;; Streaming Oracle Contract
;; Handles streaming data ingestion and royalty calculations

;; Constants
(define-constant oracle-contract-owner tx-sender)
(define-constant err-oracle-owner-only (err u200))
(define-constant err-oracle-unauthorized (err u201))
(define-constant err-oracle-invalid-data (err u202))
(define-constant err-oracle-not-found (err u203))

;; Data Variables
(define-data-var authorized-oracles (list 10 principal) (list))

;; Data Maps
(define-map streaming-data { song-id: uint, platform: (string-ascii 50), period: uint } {
    streams: uint,
    revenue: uint,
    timestamp: uint,
    verified: bool
})

(define-map platform-rates (string-ascii 50) {
    rate-per-stream: uint, ;; in micro-STX
    active: bool
})

;; Read-only functions
(define-read-only (get-streaming-data (song-id uint) (platform (string-ascii 50)) (period uint))
    (map-get? streaming-data { song-id: song-id, platform: platform, period: period })
)

(define-read-only (get-platform-rate (platform (string-ascii 50)))
    (map-get? platform-rates platform)
)

(define-read-only (is-authorized-oracle (oracle principal))
    (is-some (index-of (var-get authorized-oracles) oracle))
)

(define-read-only (calculate-period-revenue (song-id uint) (platform (string-ascii 50)) (period uint))
    (match (get-streaming-data song-id platform period)
        data (match (get-platform-rate platform)
            rate (* (get streams data) (get rate-per-stream rate))
            u0
        )
        u0
    )
)

;; Public functions
(define-public (submit-streaming-data (song-id uint) (platform (string-ascii 50)) (period uint) (streams uint))
    (let (
        (rate-data (unwrap! (get-platform-rate platform) err-oracle-not-found))
        (calculated-revenue (* streams (get rate-per-stream rate-data)))
    )
        (asserts! (is-authorized-oracle tx-sender) err-oracle-unauthorized)
        (asserts! (> streams u0) err-oracle-invalid-data)

        (map-set streaming-data
            { song-id: song-id, platform: platform, period: period }
            {
                streams: streams,
                revenue: calculated-revenue,
                timestamp: stacks-block-height,
                verified: false
            })
        (ok calculated-revenue)
    )
)

(define-public (verify-streaming-data (song-id uint) (platform (string-ascii 50)) (period uint))
    (let (
        (data (unwrap! (get-streaming-data song-id platform period) err-oracle-not-found))
    )
        (asserts! (is-eq tx-sender oracle-contract-owner) err-oracle-owner-only)

        (map-set streaming-data
            { song-id: song-id, platform: platform, period: period }
            (merge data { verified: true }))
        (ok true)
    )
)

(define-public (set-platform-rate (platform (string-ascii 50)) (rate-per-stream uint))
    (begin
        (asserts! (is-eq tx-sender oracle-contract-owner) err-oracle-owner-only)
        (asserts! (> rate-per-stream u0) err-oracle-invalid-data)

        (map-set platform-rates platform {
            rate-per-stream: rate-per-stream,
            active: true
        })
        (ok true)
    )
)

(define-public (add-authorized-oracle (oracle principal))
    (let (
        (current-oracles (var-get authorized-oracles))
    )
        (asserts! (is-eq tx-sender oracle-contract-owner) err-oracle-owner-only)
        (asserts! (not (is-authorized-oracle oracle)) err-oracle-invalid-data)

        (var-set authorized-oracles (unwrap! (as-max-len? (append current-oracles oracle) u10) err-oracle-invalid-data))
        (ok true)
    )
)

(define-public (remove-authorized-oracle (oracle principal))
    (let (
        (current-oracles (var-get authorized-oracles))
        (filtered-oracles (filter is-not-target-oracle current-oracles))
    )
        (asserts! (is-eq tx-sender oracle-contract-owner) err-oracle-owner-only)
        (var-set authorized-oracles filtered-oracles)
        (ok true)
    )
)

(define-private (is-not-target-oracle (oracle principal))
    (not (is-eq oracle tx-sender))
)
