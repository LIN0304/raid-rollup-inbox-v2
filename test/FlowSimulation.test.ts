import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract, Signer } from "ethers";

describe("RAID Flow Simulation", function () {
  // Test variables
  let feed: Contract;
  let registry: Contract;
  let inbox: Contract;
  let beaconOracle: Contract;
  let deployer: Signer, alice: Signer, bob: Signer, charlie: Signer;
  let deployerAddr: string, aliceAddr: string, bobAddr: string, charlieAddr: string;
  
  // Common test values
  const MIN_COLLATERAL = ethers.parseEther("1"); // 1 ETH
  const BEACON_ROOTS = "0x000000000000000000000000000000000000Beac";
  
  // Helper function to create validator proofs
  function createProof(slot: bigint, proposerIndex: bigint, proposerAddr: string) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["tuple(uint64,uint64,address,bytes32[])"],
      [
        [
          slot,
          proposerIndex,
          proposerAddr,
          [] // Empty branch for testing
        ]
      ]
    );
  }

  beforeEach(async function () {
    // Get signers
    [deployer, alice, bob, charlie] = await ethers.getSigners();
    deployerAddr = await deployer.getAddress();
    aliceAddr = await alice.getAddress();
    bobAddr = await bob.getAddress();
    charlieAddr = await charlie.getAddress();
    
    // Deploy contracts
    const PublicationFeed = await ethers.getContractFactory("PublicationFeed");
    feed = await PublicationFeed.deploy();
    
    const BeaconOracle = await ethers.getContractFactory("BeaconOracle");
    beaconOracle = await BeaconOracle.deploy(BEACON_ROOTS);
    
    // Deploy registry (using deployer as treasury)
    const PreconfRegistry = await ethers.getContractFactory("PreconfRegistry");
    // We'll update this with the inbox address later
    registry = await PreconfRegistry.deploy(MIN_COLLATERAL, deployerAddr, deployerAddr);
    
    // Deploy inbox
    const RaidInbox = await ethers.getContractFactory("RaidInbox");
    inbox = await RaidInbox.deploy(
      await feed.getAddress(),
      await registry.getAddress(),
      await beaconOracle.getAddress()
    );
    
    // Register Alice and Bob as preconfers
    await registry.connect(alice).join({ value: MIN_COLLATERAL });
    await registry.connect(bob).join({ value: MIN_COLLATERAL });
  });
  
  describe("Basic Flow", function () {
    it("Should handle genesis publication correctly", async function () {
      // Alice publishes first blob (genesis)
      const tx = await inbox.connect(alice).publish(
        "0xdeadbeef", // Sample blob
        1n,           // Slot 
        true,         // Must replace (genesis)
        "0x"          // Empty proof (allowed for genesis)
      );
      
      const receipt = await tx.wait();
      
      // Check events
      const newUnsafeHeadEvents = receipt.logs.filter(log => 
        log.topics[0] === inbox.interface.getEventTopic("NewUnsafeHead")
      );
      
      expect(newUnsafeHeadEvents.length).to.equal(1);
      
      // Verify state
      expect(await inbox.safeHead()).to.equal(0); // No safe head yet
      expect(await inbox.unsafeHead()).to.equal(1); // First publication
    });
    
    it("Should reject advancing unsafe head without valid proof", async function () {
      // First create a genesis publication
      await inbox.connect(alice).publish("0xdeadbeef", 1n, true, "0x");
      
      // Bob tries to advance without valid proof
      await expect(
        inbox.connect(bob).publish("0xcafebabe", 2n, false, "0x")
      ).to.be.reverted;
    });
    
    it("Should reject replacing unsafe head with same proposer", async function () {
      // First create a genesis publication
      await inbox.connect(alice).publish("0xdeadbeef", 1n, true, "0x");
      
      // Create a proof with alice as proposer
      const proof = createProof(1n, 0n, aliceAddr);
      
      // Alice tries to replace her own unsafe head
      await expect(
        inbox.connect(alice).publish("0xcafebabe", 2n, true, proof)
      ).to.be.revertedWithCustomError(inbox, "CannotReplaceWithSameProposer");
    });
  });
  
  describe("Full Flow Simulation", function () {
    it("Should handle the complete publication lifecycle", async function () {
      // Step 1: Alice publishes genesis (replaceUnsafeHead = true)
      await inbox.connect(alice).publish("0xalice1", 1n, true, "0x");
      expect(await inbox.unsafeHead()).to.equal(1);
      expect(await inbox.safeHead()).to.equal(0);
      
      // Step 2: Bob creates a proof showing Alice as proposer
      const aliceProof = createProof(1n, 0n, aliceAddr);
      
      // Bob advances the unsafe head (replaceUnsafeHead = false)
      await inbox.connect(bob).publish("0xbob1", 2n, false, aliceProof);
      expect(await inbox.unsafeHead()).to.equal(2);
      expect(await inbox.safeHead()).to.equal(1); // Alice's publication is now safe
      
      // Step 3: Alice creates a proof showing Bob as proposer
      const bobProof = createProof(2n, 1n, bobAddr);
      
      // Alice advances the unsafe head
      await inbox.connect(alice).publish("0xalice2", 3n, false, bobProof);
      expect(await inbox.unsafeHead()).to.equal(3);
      expect(await inbox.safeHead()).to.equal(2); // Bob's publication is now safe
      
      // Step 4: Charlie tries to replace Bob's unsafe head with proof of Alice
      const charlieProof = createProof(3n, 0n, aliceAddr);
      
      // Charlie joins as preconfer
      await registry.connect(charlie).join({ value: MIN_COLLATERAL });
      
      // Charlie replaces the current unsafe head
      await inbox.connect(charlie).publish("0xcharlie1", 4n, true, charlieProof);
      expect(await inbox.unsafeHead()).to.equal(4); // Charlie's publication
      expect(await inbox.safeHead()).to.equal(2); // Still Bob's publication
    });
  });
  
  describe("Slashing Mechanism", function () {
    it("Should slash a preconfer after multiple defaults", async function () {
      // Configure the inbox for quick slashing
      await inbox.setDefaultThreshold(2); // Slash after 2 defaults
      await inbox.setDefaultSlashAmount(ethers.parseEther("0.5")); // 0.5 ETH
      
      // Alice publishes genesis
      await inbox.connect(alice).publish("0xalice1", 1n, true, "0x");
      
      // Get Bob's initial collateral
      const initialCollateral = await registry.collateralOf(bobAddr);
      
      // Bob attempts to advance with invalid proof (default #1)
      await expect(
        inbox.connect(bob).publish("0xbob1", 2n, false, "0x")
      ).to.be.reverted;
      
      // Bob attempts to advance with invalid proof again (default #2)
      await expect(
        inbox.connect(bob).publish("0xbob2", 3n, false, "0x")
      ).to.be.reverted;
      
      // Bob attempts to advance with invalid proof a third time (default #3) - should trigger slashing
      await expect(
        inbox.connect(bob).publish("0xbob3", 4n, false, "0x")
      ).to.be.reverted;
      
      // Check if Bob's collateral was slashed
      const finalCollateral = await registry.collateralOf(bobAddr);
      expect(finalCollateral).to.be.lessThan(initialCollateral);
      expect(finalCollateral).to.equal(initialCollateral - ethers.parseEther("0.5"));
    });
  });
  
  describe("Administrative Functions", function () {
    it("Should allow pausing and unpausing by admin", async function () {
      // Pause the contract
      await inbox.setPaused(true);
      
      // Alice tries to publish while paused
      await expect(
        inbox.connect(alice).publish("0xalice1", 1n, true, "0x")
      ).to.be.revertedWithCustomError(inbox, "ContractPaused");
      
      // Unpause the contract
      await inbox.setPaused(false);
      
      // Alice tries again after unpausing
      await inbox.connect(alice).publish("0xalice1", 1n, true, "0x");
      expect(await inbox.unsafeHead()).to.equal(1);
    });
    
    it("Should allow admin to transfer ownership", async function () {
      // Transfer admin to Alice
      await inbox.transferAdmin(aliceAddr);
      
      // Deployer tries to pause (should fail)
      await expect(
        inbox.setPaused(true)
      ).to.be.revertedWithCustomError(inbox, "NotAdmin");
      
      // Alice pauses (should succeed)
      await inbox.connect(alice).setPaused(true);
      expect(await inbox.paused()).to.equal(true);
    });
  });
});