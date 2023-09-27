// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Staking smart contract with 4 pools
/// @notice each pool has different lockup period,
/// different apy's
contract ISOMAStaking is Ownable2Step, ReentrancyGuard {

    /// @notice StakingPool struct
    struct StakingPool {
        uint256 maxCap;
        uint256 lockedPeriod;
        uint256 apy;
        uint256 totalRewardPercent;
        uint256 totalStaked;
    }

    /// @notice User struct
    struct User {
        uint256 stakedAmount;
        uint256 lastDepositTime;
        uint256 lastRewardClaim;
        uint256 rewardClaimed;
    }

    IERC20 public token;//token
    address public feeWallet; //wallet to receive fee
    uint256 public depositFeePercentage = 1; //1% deposit fee
    uint256 public withdrawalFeePercentage = 1; //1% withdraw fee
    uint256 public penaltyPercentage = 5; // penalty fee
    uint256 public totalRewards; //total available rewards


    StakingPool[] public pools;
    mapping(uint256 => mapping(address => User)) public users; //see user stats for particular pool
    mapping(uint256 => uint256) public walletCap; // pool wise max cap per wallet
    mapping(uint256 => uint256) public poolRewards; // set pool allocation

    ///events
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount);
    event RewardClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed poolId, uint256 amount);

    ///custom errors
    error AmountShouldBeGreaterThanZero();
    error InvalidPool();
    error ExceedPoolCap();
    error NothingStaked();
    error AmountExceedStakedAmount();
    error LockupPeriodNotPassed();
    error WalletCapExceeds();
    error ZeroAddress();
    error MaxFeeCap();
    error ApyRangeExceeds();
    error InvalidMaxCapPerWallet();
    error InvalidMaxPoolLimit();
    error PercentShouldBeAtleastFive();
    error CanNotClaimMainToken();


    constructor(address _token) {
        token = IERC20(_token);
        feeWallet = msg.sender;
        walletCap[0] = 1e9 * 1e9; //max cap per wallet for first pool
        walletCap[1] = 5e8 * 1e9; //max cap per wallet for second pool
        walletCap[2] = 3e7 * 1e9; // max cap per wallet for third pool
        walletCap[3] = 2e5 * 1e9; // max cap per wallet for forth pool
        // pools setup
        pools.push(StakingPool(1e9 * 1e9, 0, 50, 5, 0));    // Pool 0: 1 billion maxCap, 0 locked period, 0.5% APY, 5% reward percentage allocation
        pools.push(StakingPool(2e9 * 1e9, 30 days, 100, 15, 0));   // Pool 1: 2 billion maxCap, 30 days locked period, 1.0% APY, 15% reward percentage allocation
        pools.push(StakingPool(3e9 * 1e9, 90 days, 150, 30, 0));  // Pool 2: 3 billion maxCap, 90 days locked period, 1.5% APY, 30% reward percentage allocation
        pools.push(StakingPool(2e9 * 1e9, 180 days, 200, 50, 0)); // pool 3; 2 billion maxCap, 180 days locked period, 2.0% APY, 50% reward percentage allocation
    }

    ///@dev inject reward to pool
    ///@param tokenAmount: number of tokens that owner want to inject to the pool
    ///Requirements-
    ///Amount must be greator than zero
    ///Owner must have approved tokenAmount before calling this function
    function injectReward(uint256 tokenAmount) external onlyOwner {
        if (tokenAmount <= 0) {revert AmountShouldBeGreaterThanZero();}
        token.transferFrom(msg.sender, (address(this)), tokenAmount);
        uint256 pool0 = (pools[0].totalRewardPercent * tokenAmount) / 100;
        uint256 pool1 = (pools[1].totalRewardPercent * tokenAmount) / 100;
        uint256 pool2 = (pools[2].totalRewardPercent * tokenAmount) / 100;
        uint256 pool3 = (pools[3].totalRewardPercent * tokenAmount) / 100;
        poolRewards[0] = poolRewards[0] + pool0;
        poolRewards[1] = poolRewards[1] + pool1;
        poolRewards[2] = poolRewards[2] + pool2;
        poolRewards[3] = poolRewards[3] + pool3;

        totalRewards = totalRewards + tokenAmount;

    }

    /// @notice user can deposit tokens to his choice of pool
    /// @param _poolId: pool id in which user want to stake
    /// @param _amountToStake: number of tokens user want to stake
    /// Requirements --
    /// number of tokens to be staked must be approved.
    /// pool id should be valid
    /// amount must greator than zero
    /// amount must be within pool cap
    /// amount must be userWalletCap for particular pool
    function deposit(uint256 _poolId, uint256 _amountToStake) external nonReentrant {

        if (_poolId >= pools.length) {revert InvalidPool();}
        if (_amountToStake <= 0) {revert AmountShouldBeGreaterThanZero();}

        StakingPool storage pool = pools[_poolId];
        if (pool.totalStaked + _amountToStake > pool.maxCap) {revert ExceedPoolCap();}

        User storage user = users[_poolId][msg.sender];
        if (user.stakedAmount + _amountToStake > walletCap[_poolId]) {revert WalletCapExceeds();}

        _claimReward(_poolId, msg.sender);
        uint256 depositFee = (_amountToStake * depositFeePercentage) / 100;
        uint256 amountAfterFee = _amountToStake - depositFee;
        if (depositFee > 0) {
            token.transferFrom(msg.sender, feeWallet, depositFee);
        }
        token.transferFrom(msg.sender, address(this), amountAfterFee);

        pool.totalStaked = pool.totalStaked + amountAfterFee;
        user.stakedAmount = user.stakedAmount + amountAfterFee;
        user.lastDepositTime = block.timestamp;
        user.lastRewardClaim = block.timestamp;

        emit Deposit(msg.sender, _poolId, amountAfterFee);
    }

    /// @notice user can withdraw his tokens
    /// @param _amountToWithdraw: number of tokens he want to withdraw
    ///@param poolId: pool id
    /// Requirements--
    /// staked amount must be greater than zero
    /// input amount must be greater than zero
    /// lock period should have been passed
    function withdraw(uint256 poolId, uint256 _amountToWithdraw) external nonReentrant {
        if (poolId >= pools.length) {revert InvalidPool();}

        StakingPool storage pool = pools[poolId];

        User storage user = users[poolId][msg.sender];

        if (user.stakedAmount == 0) {revert NothingStaked();}
        if (_amountToWithdraw == 0) {revert AmountShouldBeGreaterThanZero();}
        if (_amountToWithdraw > user.stakedAmount) {revert AmountExceedStakedAmount();}
        if (block.timestamp < user.lastDepositTime + pool.lockedPeriod) {revert LockupPeriodNotPassed();}

        uint256 withdrawalFee = (_amountToWithdraw * withdrawalFeePercentage) / 100;
        uint256 amountAfterFee = _amountToWithdraw - withdrawalFee;
        pool.totalStaked = pool.totalStaked - _amountToWithdraw;
        user.stakedAmount = user.stakedAmount - _amountToWithdraw;
        if (withdrawalFee > 0) {
            token.transfer(feeWallet, withdrawalFee);
        }
        _claimReward(poolId, msg.sender);
        token.transfer(msg.sender, amountAfterFee);

        emit Withdraw(msg.sender, poolId, _amountToWithdraw);
    }

    /// @notice user claim pending earning
    /// @param _poolId: pool id
    function claimReward(uint256 _poolId) external nonReentrant {
        _claimReward(_poolId, msg.sender);
    }

    /// @notice this function can be used to withdraw tokens earlier than lock period
    /// there is  penalty on initial deposit for doing that.
    ///@param poolId: pool id
    function emergencyWithdraw(uint256 poolId) external nonReentrant {
        if (poolId >= pools.length) {revert InvalidPool();}

        StakingPool storage pool = pools[poolId];
        User storage user = users[poolId][msg.sender];

        if (user.stakedAmount == 0) {revert NothingStaked();}

        uint256 stakedAmount = user.stakedAmount;
        uint256 penalty = (stakedAmount * penaltyPercentage) / 100;
        uint256 amountAfterPenalty = stakedAmount - penalty;

        pool.totalStaked = pool.totalStaked - stakedAmount;
        user.stakedAmount = 0;
        user.lastRewardClaim = block.timestamp;
        token.transfer(feeWallet, penalty);
        token.transfer(msg.sender, amountAfterPenalty);
        emit EmergencyWithdraw(msg.sender, poolId, amountAfterPenalty);
    }

    /// @dev update pools apy
    /// @param _poolId: pool id to be updated
    /// @param _newAPY: new apy to be set
    /// Requirements-
    /// pool id must be valid, and new apy should be greator than 0.2% and less than 50%
    function updatePoolAPY(uint256 _poolId, uint256 _newAPY) external onlyOwner {
        StakingPool storage pool = pools[_poolId];
        if (_newAPY <= 2 || _newAPY > 500) {revert ApyRangeExceeds();}
        pool.apy = _newAPY;
    }

    /// @dev update reward allocation percentage per pool
    /// @param _poolId: pool id to allocated new percentage
    /// @param newPercentage: new percentage amount
    function updateRewardAllocationPercentage(uint256 _poolId, uint256 newPercentage) external onlyOwner {
        if (_poolId >= pools.length) {revert InvalidPool();}
        if (newPercentage < 5) {revert PercentShouldBeAtleastFive();}
        StakingPool storage pool = pools[_poolId];
        pool.totalRewardPercent = newPercentage;

    }

    /// @dev update fee wallet
    /// @param newFeeWallet: owner can update the new fee wallet
    function updateFeeWallet(address newFeeWallet) external onlyOwner {
        if (newFeeWallet == address(0)) {revert ZeroAddress();}
        feeWallet = newFeeWallet;
    }

    /// @dev update max cap per wallet per pool
    /// @param poolId: pool id to set new cap per wallet
    /// @param newCap: new cap limit amount
    function updateMaxCapPerWalletForPool(uint256 poolId, uint256 newCap) external onlyOwner {
        if (poolId > pools.length) {revert InvalidPool();}
        if (newCap <= 1e3 * 1e9) {revert InvalidMaxCapPerWallet();}
        walletCap[poolId] = newCap;
    }

    /// @dev update Max pool limit (how many tokens total can be staked in particular pool)
    /// @param poolId: pool id to update max Cap
    /// @param newLimit: new cap till which user can stake in particular pool
    function updatePoolMaxLimit(uint256 poolId, uint256 newLimit) external onlyOwner {
        if (poolId > pools.length) {revert InvalidPool();}
        if (newLimit <= 1e5 * 1e9) {revert InvalidMaxPoolLimit();}
        StakingPool storage pool = pools[poolId];
        pool.maxCap = newLimit;
    }

    /// @dev update Deposit and withdrawal fee (must be within 10 percent combined)
    /// @param newDepositFee: new deposit fees
    /// @param newWithdrawlFee: new withdrawl fee
    function updateDepositAndWithdrawFee(uint256 newDepositFee, uint256 newWithdrawlFee) external onlyOwner {
        if (newDepositFee + newWithdrawlFee > 10) {revert MaxFeeCap();}
        depositFeePercentage = newDepositFee;
        withdrawalFeePercentage = newWithdrawlFee;
    }

    /// @dev owner can claim other tokens from staking contract
    /// @param otherToken: token address to be rescued
    /// Requirements - Can't claim staking token
    function claimOtherERC20Tokens(address otherToken) external onlyOwner {
        if (otherToken == address(token)) {
            revert CanNotClaimMainToken();
        }
        IERC20 tkn = IERC20(otherToken);
        uint256 balance = tkn.balanceOf(address(this));
        tkn.transfer(owner(), balance);
    }

    /// @notice internal function to handle user claim
    /// @param _poolId: pool id from which pending earning needs to be claimed
    /// @param _user: user wallet address
    /// Requirements:
    /// user staked amount must be greator than zero
    /// pool id must be valid
    function _claimReward(uint256 _poolId, address _user) private {
        if (_poolId > pools.length) {revert InvalidPool();}

        User storage user = users[_poolId][_user];

        uint256 rewards = calculateRewards(_poolId, _user);

        if (rewards > 0) {

            uint256 availableRewards = poolRewards[_poolId];

            if (availableRewards < rewards) {
                totalRewards = totalRewards - availableRewards;
                poolRewards[_poolId] = 0;
                user.rewardClaimed = user.rewardClaimed + availableRewards;
                user.lastRewardClaim = block.timestamp;
                token.transfer(_user, availableRewards);
                emit RewardClaimed(_user, _poolId, availableRewards);
            }
            else {
                totalRewards = totalRewards - rewards;
                poolRewards[_poolId] = poolRewards[_poolId] - rewards;
                user.rewardClaimed = user.rewardClaimed + rewards;
                user.lastRewardClaim = block.timestamp;
                token.transfer(_user, rewards);
                emit RewardClaimed(_user, _poolId, rewards);
            }
        }
    }

    /// @notice Returns the pending earning based on pool id and user address
    /// @param _poolId: pool id
    /// @param _user: user wallet address
    /// it calculate rewards based on fixed apy of 365 days
    function calculateRewards(uint256 _poolId, address _user) public view returns (uint256) {
        StakingPool storage pool = pools[_poolId];
        User storage user = users[_poolId][_user];

        uint256 lastRewardClaim = user.lastRewardClaim;
        uint256 stakedAmount = user.stakedAmount;
        uint256 elapsedTime = block.timestamp - lastRewardClaim;

        uint256 rewardAmount = (stakedAmount * pool.apy * elapsedTime) / (10000 * 365 days);

        return rewardAmount;
    }
}
