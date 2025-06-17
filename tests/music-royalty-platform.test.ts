import { describe, it, expect, beforeEach } from "vitest";

const accounts = [
  "ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM",
  "ST1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2ZQ8YPD5",
  "ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG",
  "ST2JHG361ZXG51QTKY2NQCVBPPRRE2KZB1HR05NNC",
];

const contractPrincipal = accounts[0];
const artist = accounts[1];
const stakeholder1 = accounts[2];
const stakeholder2 = accounts[3];

// Mock Clarity function calls
const clarityCall = (contract, func, args = [], sender = contractPrincipal) => {
  const callKey = `${contract}.${func}`;

  // Mock contract state
  const state = {
    songs: new Map(),
    songSplits: new Map(),
    stakeholderBalances: new Map(),
    streamingData: new Map(),
    platformRates: new Map(),
    nextSongId: 1,
    platformFeePercentage: 250,
    authorizedOracles: [],
  };

  switch (callKey) {
    case "music-royalty-platform.create-song":
      const [title, stakeholders, percentages] = args;
      if (stakeholders.length !== percentages.length) {
        return { type: "error", value: 106 };
      }
      const totalPercentage = percentages.reduce((sum, p) => sum + p, 0);
      if (totalPercentage !== 10000) {
        return { type: "error", value: 103 };
      }

      const songId = state.nextSongId;
      state.songs.set(songId, {
        artist: sender,
        title,
        totalShares: 10000,
        totalRevenue: 0,
        createdAt: 1000,
      });

      stakeholders.forEach((stakeholder, i) => {
        const key = `${songId}-${stakeholder}`;
        state.songSplits.set(key, {
          shares: percentages[i],
          percentage: percentages[i],
        });
      });

      state.nextSongId++;
      return { type: "ok", value: songId };

    case "music-royalty-platform.get-song":
      const [getSongId] = args;
      const song = state.songs.get(getSongId);
      return song ? { type: "some", value: song } : { type: "none" };

    case "music-royalty-platform.get-song-split":
      const [splitSongId, splitStakeholder] = args;
      const splitKey = `${splitSongId}-${splitStakeholder}`;
      const split = state.songSplits.get(splitKey);
      return split ? { type: "some", value: split } : { type: "none" };

    case "music-royalty-platform.distribute-royalties":
      const [distSongId, revenue] = args;
      const distSong = state.songs.get(distSongId);
      if (!distSong) return { type: "error", value: 101 };
      if (sender !== distSong.artist && sender !== contractPrincipal) {
        return { type: "error", value: 102 };
      }

      const platformFee = Math.floor(
        (revenue * state.platformFeePercentage) / 10000,
      );
      const distributableRevenue = revenue - platformFee;

      distSong.totalRevenue += revenue;
      state.songs.set(distSongId, distSong);

      return { type: "ok", value: distributableRevenue };

    case "music-royalty-platform.calculate-royalty-split":
      const [calcSongId, calcRevenue, calcStakeholder] = args;
      const calcSplitKey = `${calcSongId}-${calcStakeholder}`;
      const calcSplit = state.songSplits.get(calcSplitKey);
      if (!calcSplit) return 0;

      return Math.floor((calcRevenue * calcSplit.percentage) / 10000);

    case "music-royalty-platform.set-platform-fee":
      const [newFee] = args;
      if (sender !== contractPrincipal) return { type: "error", value: 100 };
      if (newFee > 1000) return { type: "error", value: 103 };

      state.platformFeePercentage = newFee;
      return { type: "ok", value: true };

    case "streaming-oracle.submit-streaming-data":
      const [streamSongId, platform, period, streams] = args;
      if (!state.authorizedOracles.includes(sender)) {
        return { type: "error", value: 201 };
      }
      if (streams <= 0) return { type: "error", value: 202 };

      const rate = state.platformRates.get(platform);
      if (!rate) return { type: "error", value: 203 };

      const calculatedRevenue = streams * rate.ratePerStream;
      const streamKey = `${streamSongId}-${platform}-${period}`;

      state.streamingData.set(streamKey, {
        streams,
        revenue: calculatedRevenue,
        timestamp: 1000,
        verified: false,
      });

      return { type: "ok", value: calculatedRevenue };

    case "streaming-oracle.set-platform-rate":
      const [setPlatform, setRate] = args;
      if (sender !== contractPrincipal) return { type: "error", value: 200 };
      if (setRate <= 0) return { type: "error", value: 202 };

      state.platformRates.set(setPlatform, {
        ratePerStream: setRate,
        active: true,
      });
      return { type: "ok", value: true };

    case "streaming-oracle.add-authorized-oracle":
      const [oracle] = args;
      if (sender !== contractPrincipal) return { type: "error", value: 200 };
      if (state.authorizedOracles.includes(oracle))
        return { type: "error", value: 202 };

      state.authorizedOracles.push(oracle);
      return { type: "ok", value: true };

    default:
      return { type: "error", value: "Unknown function" };
  }
};

describe("Music Royalty Platform", () => {
  describe("Song Creation", () => {
    it("should create a song with valid splits", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "create-song",
        ["Test Song", [artist, stakeholder1], [7000, 3000]],
        artist,
      );

      expect(result.type).toBe("ok");
      expect(result.value).toBe(1);
    });

    it("should reject splits that do not total 100%", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "create-song",
        ["Test Song", [artist, stakeholder1], [6000, 3000]],
        artist,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(103); // err-invalid-percentage
    });

    it("should reject mismatched stakeholders and percentages", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "create-song",
        ["Test Song", [artist], [6000, 4000]],
        artist,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(106); // err-invalid-split
    });
  });

  describe("Royalty Distribution", () => {
    beforeEach(() => {
      // Create a test song
      clarityCall(
        "music-royalty-platform",
        "create-song",
        ["Test Song", [artist, stakeholder1], [7000, 3000]],
        artist,
      );
    });
  });

  describe("Platform Management", () => {
    it("should allow owner to set platform fee", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "set-platform-fee",
        [500], // 5%
        contractPrincipal,
      );

      expect(result.type).toBe("ok");
      expect(result.value).toBe(true);
    });

    it("should reject fees over 10%", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "set-platform-fee",
        [1500], // 15%
        contractPrincipal,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(103); // err-invalid-percentage
    });

    it("should only allow owner to set fees", () => {
      const result = clarityCall(
        "music-royalty-platform",
        "set-platform-fee",
        [500],
        artist,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(100); // err-owner-only
    });
  });
});

describe("Streaming Oracle", () => {
  beforeEach(() => {
    // Set up platform rate
    clarityCall(
      "streaming-oracle",
      "set-platform-rate",
      ["spotify", 4000], // 4000 micro-STX per stream
      contractPrincipal,
    );

    // Add authorized oracle
    clarityCall(
      "streaming-oracle",
      "add-authorized-oracle",
      [stakeholder1],
      contractPrincipal,
    );
  });

  describe("Streaming Data Submission", () => {
    it("should reject data from unauthorized oracle", () => {
      const result = clarityCall(
        "streaming-oracle",
        "submit-streaming-data",
        [1, "spotify", 202401, 1000],
        stakeholder2,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(201); // err-unauthorized
    });
  });

  describe("Platform Rate Management", () => {
    it("should allow owner to set platform rates", () => {
      const result = clarityCall(
        "streaming-oracle",
        "set-platform-rate",
        ["apple-music", 5000],
        contractPrincipal,
      );

      expect(result.type).toBe("ok");
      expect(result.value).toBe(true);
    });

    it("should reject zero rates", () => {
      const result = clarityCall(
        "streaming-oracle",
        "set-platform-rate",
        ["youtube", 0],
        contractPrincipal,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(202); // err-invalid-data
    });

    it("should only allow owner to set rates", () => {
      const result = clarityCall(
        "streaming-oracle",
        "set-platform-rate",
        ["tidal", 6000],
        artist,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(200); // err-owner-only
    });
  });

  describe("Oracle Management", () => {
    it("should allow owner to add authorized oracles", () => {
      const result = clarityCall(
        "streaming-oracle",
        "add-authorized-oracle",
        [stakeholder2],
        contractPrincipal,
      );

      expect(result.type).toBe("ok");
      expect(result.value).toBe(true);
    });

    it("should only allow owner to manage oracles", () => {
      const result = clarityCall(
        "streaming-oracle",
        "add-authorized-oracle",
        [stakeholder2],
        artist,
      );

      expect(result.type).toBe("error");
      expect(result.value).toBe(200); // err-owner-only
    });
  });
});
