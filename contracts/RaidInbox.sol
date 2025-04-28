// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IRaidInbox }          from "./interfaces/IRaidInbox.sol";
import { IBeaconRoots }        from "./interfaces/IBeaconRoots.sol";
import { PublicationFeed }     from "./PublicationFeed.sol";
import { PreconfRegistry }     from "./PreconfRegistry.sol";
import { ValidatorProofVerifier as V } from "./validator/ValidatorProofVerifier.sol";

/// @title RaidInbox
/// @notice Core contract implementing the unsafeHead / safeHead state‑machine
///         described in the RAID spec.
contract RaidInbox is IRaidInbox {
    /*//////////////////////////////////////////////////////////////
                               CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    error NotPreconfer(address sender);
    error MustReplaceGenesis();
    error InvalidProof();
    error CannotReplaceWithSameProposer(address proposer);
    error CannotAdvanceWithDifferentProposer(address proposerA, address proposerB);
    error ContractPaused();
    error NotAdmin(address sender);
    
    /*//////////////////////////////////////////////////////////////
                                PARAMS
    //////////////////////////////////////////////////////////////*/
    PublicationFeed  public immutable feed;
    PreconfRegistry  public immutable registry;
    IBeaconRoots     public immutable beacon;   // EIP‑4788 ring‑buffer
    
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    uint256 public override safeHead;         // last canonical publication
    uint256 public override unsafeHead;       // candidate waiting for confirmation
    bool public paused;                       // emergency pause switch
    address public admin;                     // admin address for emergency controls
    
    // Track defaulting preconfers
    mapping(address => uint256) public defaultCount;
    uint256 public defaultThreshold = 3;      // Number of defaults before slashing
    uint256 public defaultSlashAmount = 0.1 ether; // Amount to slash per default after threshold
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event AdminChanged(address oldAdmin, address newAdmin);
    event PauseStateChanged(bool paused);
    event DefaultThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event DefaultSlashAmountChanged(uint256 oldAmount, uint256 newAmount);
    event PreconferDefaulted(address preconfer, uint256 defaultCount);
    
    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /// @dev Prevents functions from being called when the contract is paused
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }
    
    /// @dev Only allows the admin to call the function
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }
    
    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _feed,
        address _registry,
        address _beaconRoots
    ) {
        require(_feed != address(0), "zero-feed-address");
        require(_registry != address(0), "zero-registry-address");
        require(_beaconRoots != address(0), "zero-beacon-address");
        
        feed = PublicationFeed(_feed);
        registry = PreconfRegistry(_registry);
        beacon = IBeaconRoots(_beaconRoots);
        admin = msg.sender;
    }
    
    /*//////////////////////////////////////////////////////////////
                             ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Pauses or unpauses the contract
    /// @param _paused The new paused state
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PauseStateChanged(_paused);
    }
    
    /// @notice Transfers admin role to a new address
    /// @param newAdmin The new admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "zero-address");
        address oldAdmin = admin;
        admin = newAdmin;
        emit AdminChanged(oldAdmin, newAdmin);
    }
    
    /// @notice Sets the default threshold before slashing starts
    /// @param newThreshold The new threshold value
    function setDefaultThreshold(uint256 newThreshold) external onlyAdmin {
        uint256 oldThreshold = defaultThreshold;
        defaultThreshold = newThreshold;
        emit DefaultThresholdChanged(oldThreshold, newThreshold);
    }
    
    /// @notice Sets the amount to slash per default after threshold
    /// @param newAmount The new slash amount
    function setDefaultSlashAmount(uint256 newAmount) external onlyAdmin {
        uint256 oldAmount = defaultSlashAmount;
        defaultSlashAmount = newAmount;
        emit DefaultSlashAmountChanged(oldAmount, newAmount);
    }
    
    /*//////////////////////////////////////////////////////////////
                          EXTERNAL PUBLISH API
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc IRaidInbox
    function publish(
        bytes calldata blob,
        uint64 slot,
        bool   replaceUnsafeHead,
        bytes calldata validatorProof
    )
        external
        override
        whenNotPaused
        returns (uint256 pid)
    {
        /// ----------------------------------------------------------------
        /// 0. Preconditions
        /// ----------------------------------------------------------------
        if (!registry.isActivePreconfer(msg.sender)) {
            revert NotPreconfer(msg.sender);
        }
        
        // Publish to feed (this will also check slot ordering)
        pid = feed.publish(blob, slot);

        /// ----------------------------------------------------------------
        /// 1. No previous unsafe head → trivial set
        /// ----------------------------------------------------------------
        if (unsafeHead == 0) {
            if (!replaceUnsafeHead) {
                revert MustReplaceGenesis();
            }
            unsafeHead = pid;
            emit NewUnsafeHead(pid, msg.sender);
            return pid;
        }

        /// ----------------------------------------------------------------
        /// 2. Fetch previous publication & build proof struct
        /// ----------------------------------------------------------------
        PublicationFeed.Publication memory prev = feed.publications(unsafeHead);
        
        // Decode proof
        V.Proof memory proof;
        try abi.decode(validatorProof, (V.Proof)) returns (V.Proof memory decodedProof) {
            proof = decodedProof;
        } catch {
            _handleDefault(msg.sender);
            revert InvalidProof();
        }

        // Verify proof against beacon roots
        try proof.verify(beacon) {
            // Proof valid, continue
        } catch {
            // Track default and potentially slash
            _handleDefault(msg.sender);
            revert InvalidProof();
        }

        /// ----------------------------------------------------------------
        /// 3. Replace or Advance
        /// ----------------------------------------------------------------
        if (replaceUnsafeHead) {
            // Proof must show *different* proposer than prev.publisher
            if (proof.proposerAddr == prev.publisher) {
                revert CannotReplaceWithSameProposer(prev.publisher);
            }
            
            unsafeHead = pid;
            emit NewUnsafeHead(pid, msg.sender);
        } else {
            // Proof must show *same* proposer as prev.publisher
            if (proof.proposerAddr != prev.publisher) {
                revert CannotAdvanceWithDifferentProposer(proof.proposerAddr, prev.publisher);
            }
            
            // Promote to safe
            safeHead = unsafeHead;
            emit NewSafeHead(safeHead, prev.publisher);
            
            // Shift new pid into unsafe
            unsafeHead = pid;
            emit NewUnsafeHead(pid, msg.sender);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev Handles a preconfer default by tracking count and potentially slashing
    /// @param preconfer The address of the defaulting preconfer
    function _handleDefault(address preconfer) internal {
        defaultCount[preconfer]++;
        emit PreconferDefaulted(preconfer, defaultCount[preconfer]);
        
        // Slash after threshold is reached
        if (defaultCount[preconfer] > defaultThreshold) {
            registry.slash(
                preconfer, 
                defaultSlashAmount, 
                string(abi.encodePacked("Default #", defaultCount[preconfer]))
            );
        }
    }
}