// SPDX-License-Identifier: MIT
// This contract implements a Decentralized Autonomous Organization (DAO) Pool for managing staking and rewards distribution.
// Users can stake a token to receive yToken as the staking certificate together with the associated rewards and participate in governance.
// The DAO supports penalty allocations and configurable parameters such as reward rate and withdrawal fee.
// Written by zkSwap Finance, 2024.

pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./yZFToken.sol";

interface IZFToken is IERC20 {
    function mint(address account, uint256 amount) external;
}

contract ZFGovernanceStaking is yZFToken, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct PenaltyInfo {
        address desAddress;
        uint256 allocation;
    }

    mapping(address => uint256) private stakedAmounts;

    PenaltyInfo[] public penaltyList;
    
    // Penalty fee in basis points (1% coressponding to 1e10)
    uint256 public penaltyPercent = 1e10; // 1%
    uint256 public constant PRECISION = 1e12;
    uint256 public constant MAX_FEE = 1e11; // 10%
    uint256 public constant MAX_ALLOCATION_RATIO = 1e12; // 100%

    address private constant ZERO_ADDRESS = address(0);

    address immutable public zfToken;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public zfLastRewardTime;
    uint256 public zfRewardRate;

    constructor(
        address token,
        uint256 startTimestamp,
        uint256 endTimestamp,
        uint256 zfPersecond 
    )
        yZFToken()
    {
        require(token != ZERO_ADDRESS, "Illegal token address");
        zfToken = token;
        startTime = startTimestamp;
        endTime = endTimestamp;
        zfLastRewardTime = startTimestamp;
        zfRewardRate = zfPersecond;
    }

    event Stake(address indexed user, uint256 indexed amount, uint256 indexed share);
    event Unstake(address indexed user, uint256 indexed withdrawAmount, uint256 indexed share);

    event SetPenaltyAllocation(uint256 idx, address dst, uint256 percent);
    event AddPenaltyAllocation(address dst, uint256 percent);
    event RemovePenaltyAllocation(uint256 penaltyIdx);

    event SetPenaltyPercent(uint256 newFee);
    event SetStartTime(uint256 startTime);
    event SetEndTime(uint256 endTime);
    event SetRewardRate(uint256 newRewardRate);


    // VIEW FUNCTION

    function balance() public view returns (uint256) {
        return IERC20(zfToken).balanceOf(address(this));
    }

    // Get the price of ZF per yZF tokens (how much ZF for 1 yZF).
    function getZFPricePerFullShare() public view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 _pool = balance() + pendingZF();
        return (_pool * 1e18) / totalSupply;
    }

    // Get the price of yZF per ZF tokens (how much yZF for 1 ZF).
    function getYZFPricePerFullShare() external view returns (uint256) {
        uint256 _pool = balance() + pendingZF();
        return (totalSupply * 1e18) / _pool;
    }

    // Calculate reward multiplier based on time.
    function getMultiplier(uint256 from, uint256 to) internal pure returns (uint256) {
        if (to <= from) return 0;
        return to - from;
    }

    // Calculate pending ZF rewards.
    function pendingZF() public view returns (uint256 zfPending) {
        uint256 currentTime = block.timestamp >= endTime ? endTime : block.timestamp;
        uint256 multiplier = getMultiplier(zfLastRewardTime, currentTime);
        zfPending = zfRewardRate * multiplier;
    }

    // Get stakedAmount and current reward for a user.
    function getUserInfo(address user) external view returns (uint256 stakedAmount, uint256 currentReward) {
        uint256 cumulativeAmounts = balanceOf(user) * getZFPricePerFullShare() / 1e18;
        stakedAmount = stakedAmounts[user];
        currentReward = cumulativeAmounts - stakedAmount;
    }

    /// CORE FUNCTION

    //Stake tokens to receive yZF tokens.
    function stake(uint256 amount) nonReentrant external {
        uint256 poolBalance = balance();
        uint256 pendingAmount = pendingZF();
        
        if (pendingAmount > 0) {
            IZFToken(zfToken).mint(address(this), pendingAmount);
            zfLastRewardTime = block.timestamp;
            poolBalance = balance();
        }
        
        if (amount == 0) return; // Harvest Pool only

        uint256 shares = 0;
        if (totalSupply == 0) {
            shares = amount;
        }
        else {
            shares = amount * totalSupply / poolBalance;
        }

        // Stake ZF, receive yZF
        IERC20(zfToken).safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);

        emit Stake(msg.sender, amount, shares);

        // update the staked amount of the user
        updateZFStakedAmount(msg.sender);
    }

    // Unstake yZF tokens to get back staked ZF together with the rewards.
    // Penalty is distributed by default to other stakers in the pool and other destinations in the Penalty List, if any.
    function unstake(uint256 shares) nonReentrant external {

        // Harvest ZF reward
        uint256 pendingAmount = pendingZF();
        if (pendingAmount > 0) {
            IZFToken(zfToken).mint(address(this), pendingAmount);
            zfLastRewardTime = block.timestamp;
        }

        if (shares == 0) return; // Harvest Pool only

        // Penalty
        uint256 withdrawAmount = balance() * shares / totalSupply;
        uint256 penaltyAmount = withdrawAmount * penaltyPercent / PRECISION;
        withdrawAmount = withdrawAmount - penaltyAmount;

        // Allocate and distribute penalty amount
        distributePenalty(penaltyAmount);

        // unstake ZF
        _burn(msg.sender, shares);
        IERC20(zfToken).safeTransfer(msg.sender, withdrawAmount);
        emit Unstake(msg.sender, withdrawAmount, shares);

        // update the staked amount of the user
        updateZFStakedAmount(msg.sender);
    }

    // Function for updating the staked amount of a user.
    // The stakedAmount information of a user is updated every time there is an action initiated by the user.
    function updateZFStakedAmount(address user) private {
        uint256 stakedAmount = balanceOf(user) * getZFPricePerFullShare() / 1e18;
        stakedAmounts[user] = stakedAmount;
    }

    // The _transferTokens function is overridden with updateZFStakedAmount calls to update the user's staking information.
    function _transferTokens(address src, address dst, uint96 amount) override internal {
        require(src != address(0), "Uni::_transferTokens: cannot transfer from the zero address");
        require(dst != address(0), "Uni::_transferTokens: cannot transfer to the zero address");

        balances[src] = sub96(balances[src], amount, "Uni::_transferTokens: transfer amount exceeds balance");
        balances[dst] = add96(balances[dst], amount, "Uni::_transferTokens: transfer amount overflows");
        emit Transfer(src, dst, amount);

        _moveDelegates(delegates[src], delegates[dst], amount);
        
        // update the staked amount of the user
        updateZFStakedAmount(src);
        updateZFStakedAmount(dst);

    }

    // Distribute penalty amount among penalty destinations, if any.
    // By default, the penalty is distributed to other stakers still in the pool.
    function distributePenalty(uint256 penaltyAmount) private {

        for (uint256 i=0; i < penaltyList.length;)  {
            PenaltyInfo memory penaltyInfo = penaltyList[i];

            uint256 amount = penaltyAmount * penaltyInfo.allocation / PRECISION;
            IERC20(zfToken).safeTransfer(penaltyInfo.desAddress, amount);

            unchecked {
                ++i;
            }
        }

    }

    /// ADMIN FUNCTION

    // Set penalty allocation for a penalty destination.
    function setPenaltyAllocation(uint256 idx, address dst, uint256 allocation) external onlyOwner {
        require (dst != ZERO_ADDRESS, "setPenaltyAllocation:Illegal destination address");
        require(allocation <= MAX_ALLOCATION_RATIO, "setPenaltyAllocation:invalid allocation");

        PenaltyInfo storage penaltyInfo = penaltyList[idx];
        penaltyInfo.desAddress = dst;
        penaltyInfo.allocation = allocation;

        emit SetPenaltyAllocation(idx, dst, allocation);
    }

    // Add new penalty penalty destination and its allocation.
    function addPenaltyAllocation(address dst, uint256 allocation) external onlyOwner {
        require(dst!= ZERO_ADDRESS, "addPenaltyAllocation: Illegal destination address");
        require(allocation <= MAX_ALLOCATION_RATIO, "addPenaltyAllocation: invalid allocation");

        penaltyList.push(PenaltyInfo({
            desAddress: dst,
            allocation: allocation
        }));
        emit AddPenaltyAllocation(dst, allocation);
    }

    // Remove a penalty destination and its allocation.
    function removePenaltyAllocation(uint256 pid) external onlyOwner {
        require(pid < penaltyList.length, "removePenaltyAllocation: invalid penalty index");

        if (pid < (penaltyList.length - 1)) {
            for (uint256 i = pid; i < penaltyList.length; ) {
                penaltyList[i] = penaltyList[i + 1];
                unchecked {
                    ++i;
                }
            }
        }

        penaltyList.pop();
        emit RemovePenaltyAllocation(pid);
    }

    // Set the penalty (withdrawal) percentage.
    function setPenaltyPercent(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "setPenaltyPercent: invalid newFee");
        penaltyPercent = newFee;
        emit SetPenaltyPercent(newFee);
    }

    // Set the start time of the staking period.
    function setStartTime(uint256 startTimestamp) external onlyOwner {
        startTime = startTimestamp;
        zfLastRewardTime = startTimestamp;

        emit SetStartTime(startTimestamp);
    }

    // Set the end time of the staking period.
    function setEndTime(uint256 endTimestamp) external onlyOwner {
        endTime = endTimestamp;

        emit SetStartTime(endTimestamp);
    }

    // Set the ZF reward rate (per second).
    function setRewardRate(uint256 newRewardRate) external onlyOwner {
        zfRewardRate = newRewardRate;

        emit SetRewardRate(newRewardRate);
    }
}
