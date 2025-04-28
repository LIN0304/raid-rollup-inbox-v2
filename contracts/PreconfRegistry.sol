// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title PreconfRegistry
/// @notice Tracks which addresses have opted‑in to act as *preconfer*
///         (a.k.a. blob proposer) and enforces collateral.
///         The collateral can later be slashed if they break pre‑confirmations.
contract PreconfRegistry {
    /*//////////////////////////////////////////////////////////////
                               CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/
    error AlreadyJoined(address preconfer);
    error NotMember(address sender);
    error InsufficientCollateral(uint256 provided, uint256 required);
    error ETHTransferFailed(address recipient, uint256 amount);
    error NotAuthorized(address sender, address expected);
    error ReentrancyGuard();

    /*//////////////////////////////////////////////////////////////
                                PARAMS
    //////////////////////////////////////////////////////////////*/
    uint256 public immutable minCollateral;   // e.g. 1 ETH
    address public immutable raidTreasury;    // slashed collateral receiver
    address public immutable raidInbox;       // only contract allowed to slash

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    mapping(address => uint256) public collateralOf;
    mapping(address => bool)    public isActivePreconfer;
    bool private _locked; // Reentrancy guard

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Joined(address indexed preconfer, uint256 collateral);
    event Exited(address indexed preconfer);
    event Slashed(address indexed offender, uint256 amount, string reason);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(uint256 _minCollateral, address _treasury, address _raidInbox) payable {
        require(_treasury != address(0), "zero-treasury-address");
        require(_raidInbox != address(0), "zero-inbox-address");
        
        minCollateral = _minCollateral;
        raidTreasury  = _treasury;
        raidInbox     = _raidInbox;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    /// @dev Prevents reentrancy attacks
    modifier nonReentrant() {
        if (_locked) revert ReentrancyGuard();
        _locked = true;
        _;
        _locked = false;
    }
    
    /// @dev Only allows the RaidInbox contract to call the function
    modifier onlyRaidInbox() {
        if (msg.sender != raidInbox) {
            revert NotAuthorized(msg.sender, raidInbox);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         ON‑BOARDING / OFF‑BOARDING
    //////////////////////////////////////////////////////////////*/
    /// @notice Allows a user to join as a preconfer by depositing collateral
    function join() external payable nonReentrant {
        if (isActivePreconfer[msg.sender]) {
            revert AlreadyJoined(msg.sender);
        }
        
        if (msg.value < minCollateral) {
            revert InsufficientCollateral(msg.value, minCollateral);
        }
        
        collateralOf[msg.sender] = msg.value;
        isActivePreconfer[msg.sender] = true;
        
        emit Joined(msg.sender, msg.value);
    }

    /// @notice Allows a preconfer to exit and withdraw their collateral
    function exit() external nonReentrant {
        if (!isActivePreconfer[msg.sender]) {
            revert NotMember(msg.sender);
        }
        
        uint256 bal = collateralOf[msg.sender];
        collateralOf[msg.sender] = 0;
        isActivePreconfer[msg.sender] = false;
        
        (bool ok,) = payable(msg.sender).call{value: bal}("");
        if (!ok) {
            revert ETHTransferFailed(msg.sender, bal);
        }
        
        emit Exited(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                             SLASHING HOOK
    //////////////////////////////////////////////////////////////*/
    /// @notice Slashes collateral from an offending preconfer
    /// @param offender The address of the offender
    /// @param amount The amount to slash
    /// @param reason The reason for slashing
    function slash(address offender, uint256 amount, string calldata reason) external onlyRaidInbox {
        uint256 bal = collateralOf[offender];
        uint256 seize = amount > bal ? bal : amount;
        
        if (seize > 0) {
            collateralOf[offender] = bal - seize;
            
            (bool ok,) = payable(raidTreasury).call{value: seize}("");
            if (!ok) {
                revert ETHTransferFailed(raidTreasury, seize);
            }
            
            emit Slashed(offender, seize, reason);
        }
    }
}