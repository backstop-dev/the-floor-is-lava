// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

/**
 * @title Lava
 * @dev Implementation of a custom ERC20 token with automated backstop funding via transaction fees and direct contributions.
 *      This contract accumulates funds in a backstop pool through transaction fees, which are then swapped for ether using Uniswap V2.
 *      The swapping process is triggered manually, by anybody, and can only be executed based on certain accumulated amounts and predefined time intervals,
 *      optimizing transaction costs and minimizing market impact.
 *
 *      Each transaction incurs by default a 2% fee, allocated to the backstop pool. Out of this fee, 20% (equivalent to 0.4% of the total transaction)
 *      is directed to the owner as a project funding fee.
 *
 *      Initially, tokens are minted to the owner for purposes such as airdrops and seeding liquidity pools. The owner has the capability
 *      to conduct airdrops using their own tokens and register addresses that do not pay a contribution on transfers
 *      but is prohibited from minting new tokens or performing any other privileged actions,
 *      thereby ensuring a fixed supply post-initial minting phase.

 *      This project uses the default 18 decimals used in ERC20 tokens, facilitating standard calculation and exchange.
 */
contract Lava is ERC20, ERC20Permit, Ownable {
    uint8 public nbrSwaps = 1;
    uint8 public buyContributionPer10000 = 200;
    uint8 public sellContributionPer10000 = 200;
    uint8 public transferContributionPer10000 = 200;

    uint256 public deltaSwapAmount = 0.0025 ether;
    uint256 public usableBackstopPool;
    uint256 public backstopFundingAccumulated;
    uint256 public lastTransferTime;

    IUniswapV2Router02 public uniswap2Router;
    address public uniswapPair;
    mapping(address => bool) public nonContributingAddresses;

    uint8 public constant MAX_CONTRIBUTION_PER_10000 = 200;
    uint8 public constant PROJECT_FUNDING_SUB_PRC = 20;
    uint8 public constant NET_BACKSTOP_PRC = 90;
    uint8 public constant STEPS_CAP = 40;

    uint256 public constant SHORT_TRANSFER_INTERVAL = 5 minutes;
    uint256 public constant LONG_TRANSFER_INTERVAL = 7 days;
    uint256 public constant MAX_DELTA_SWAP_AMOUNT = 0.01 ether;

    event TokensAirdropped(uint256 indexed totalAmount, address[] indexed recipients, uint256[] indexed amounts);
    event TokensBurned(address indexed caller, uint256 indexed amount, uint256 indexed backstop);
    event ContributionsSentToRouter(address indexed routerAddress, uint256 indexed tokensIn);
    event LavaFundsReceived(address indexed sender, uint256 indexed amount);
    event TokenFundsReceived(address indexed sender, uint256 indexed amount);
    event ParametersUpdated(uint8 indexed buyPrc, uint8 indexed sellPrc, uint8 indexed transferPrc, uint256 swapDelta);
    event NonContributingAddressUpdated(address indexed target, bool indexed isContributing);

    error LavaEmptySupply();
    error LavaArraysLengthMismatch();
    error LavaBurningRefundFailed(address caller, uint256 amount, uint256 backstop);
    error LavaSwapDeltaTooHigh(uint256 swapDelta);
    error LavaContributionTooHigh(uint8 buyPrc, uint8 sellPrc, uint8 transferPrc);
    error LavaSwapNotReady(uint256 tokensAccumulated, uint256 timeSinceLastDistribution);

    /**
     * @dev Constructor for deploying the token with initial settings.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param initialAmount Initial mint amount (scaled by decimals).
     * @param teamWallet Address of the team wallet for receiving project funds.
     * @param routerAddress Address of the Uniswap V2 router for token swaps.
     */
    constructor(string memory name, string memory symbol, uint256 initialAmount, address teamWallet, address routerAddress)
    ERC20(name, symbol)
    ERC20Permit(name)
    Ownable(teamWallet)
    {
        if (initialAmount == 0) revert LavaEmptySupply();
        _mint(owner(), initialAmount * 10 ** decimals());
        uniswap2Router = IUniswapV2Router02(routerAddress);
        uniswapPair = IUniswapV2Factory(uniswap2Router.factory())
            .createPair(address(this), uniswap2Router.WETH());
        lastTransferTime = block.timestamp;

        nonContributingAddresses[routerAddress] = true;
        nonContributingAddresses[uniswapPair] = true;
    }

    /**
     * @dev Burns tokens and refunds a proportionate amount of ETH from the backstop pool.
     * @param amount The amount of tokens to burn.
     */
    function burn(uint256 amount) external {
        uint256 backstop = NET_BACKSTOP_PRC * usableBackstopPool * amount / totalSupply() / 100;
        _burn(_msgSender(), amount);

        if (totalSupply() == 0) {
            backstop = usableBackstopPool;
        }
        usableBackstopPool -= backstop;

        if (backstop > 0) {
            (bool sent,) = payable(_msgSender()).call{value: backstop}("");
            if (!sent) revert LavaBurningRefundFailed(_msgSender(), amount, backstop);
        }

        emit TokensBurned(_msgSender(), amount, backstop);
    }

    /**
     * @dev Overrides the ERC20 transfer function to include funding logic.
     * @param to The recipient address.
     * @param value The amount of tokens to send.
     * @return Returns true on success.
     */
    function transfer(address to, uint256 value) public virtual override returns (bool) {
        _processTransfer(_msgSender(), to, value);
        return true;
    }

    /**
     * @dev Overrides the ERC20 transferFrom function to include funding logic.
     * @param from The sender address.
     * @param to The recipient address.
     * @param value The amount of tokens to send.
     * @return Returns true on success.
     */
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _processTransfer(from, to, value);
        return true;
    }

    /**
     * @dev Defines the transfer logic for the token.
     * @param to The recipient address.
     * @param value The amount of tokens to send.
     */
    function _processTransfer(address from, address to, uint256 value) internal {
        uint256 collectedContribution = 0;
        if (from == address(this)) {
        }
        else if (to == address(this)) {
            backstopFundingAccumulated += value;
            emit TokenFundsReceived(from, value);
        }
        else if (from == address(uniswap2Router)) {
            collectedContribution = value * buyContributionPer10000 / 10000;
        }
        else if (to == uniswapPair) {
            collectedContribution = value * sellContributionPer10000 / 10000;
        }
        else if (!nonContributingAddresses[from] && !nonContributingAddresses[to]) {
            collectedContribution = value * transferContributionPer10000 / 10000;
        }

        if (collectedContribution > 0) {
            backstopFundingAccumulated += collectedContribution;
            _transfer(from, to, value - collectedContribution);
            _transfer(from, address(this), collectedContribution);

            if (owner() != address(0)) {
                uint256 projectPortion = collectedContribution * PROJECT_FUNDING_SUB_PRC / 100;
                backstopFundingAccumulated -= projectPortion;
                _transfer(address(this), owner(), projectPortion);
            }
        } else {
            _transfer(from, to, value);
        }
    }

    /**
     * @dev Allows the owner to airdrop tokens to multiple recipients.
     * @param recipients An array of recipient addresses.
     * @param values An array of token amounts corresponding to each recipient.
     */
    function airdrop(address[] calldata recipients, uint256[] calldata values) public onlyOwner {
        if (recipients.length != values.length) revert LavaArraysLengthMismatch();

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < recipients.length; i++) {

            totalAmount += values[i];
            _transfer(_msgSender(), recipients[i], values[i]);
            if (recipients[i] == address(this)) {

                backstopFundingAccumulated += values[i];
                emit TokenFundsReceived(_msgSender(), values[i]);
            }
        }

        emit TokensAirdropped(totalAmount, recipients, values);
    }

    /**
     * @dev Allows the owner to register addresses that should not contribute to the backstop pool.
     * @param target The address to be registered.
     */
    function registerNonContributingAddress(address target) public onlyOwner {
        nonContributingAddresses[target] = true;
        emit NonContributingAddressUpdated(target, true);
    }

    /**
     * @dev Allows the owner to remove addresses from the non-contributing list.
     * @param target The address to be removed.
     */
    function removeNonContributingAddress(address target) public onlyOwner {
        delete nonContributingAddresses[target];
        emit NonContributingAddressUpdated(target, false);
    }

    /**
 * @dev Fetches the current ETH quote for a given amount of tokens using the Uniswap V2 router.
     * @param amount The amount of tokens to quote.
     * @return Returns the amount of ETH that can be received for the given token amount.
     */
    function getQuote(uint256 amount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswap2Router.WETH();

        uint[] memory amountOutMins = uniswap2Router.getAmountsOut(amount, path);
        return amountOutMins[1];
    }

    /**
* @dev Function to determine if a swap for ETH should occur based on time and value thresholds.
     * @return Returns true if a swap could be attempted.
     */
    function canSwapBackstop() public view returns (bool) {
        uint256 timeSinceLastTransfer = block.timestamp - lastTransferTime;
        if (timeSinceLastTransfer < SHORT_TRANSFER_INTERVAL) {
            return false;
        }

        uint256 value = getQuote(backstopFundingAccumulated);
        return (value >= deltaSwapAmount * nbrSwaps)
            ||
            (timeSinceLastTransfer >= LONG_TRANSFER_INTERVAL && value >= deltaSwapAmount);
    }

    /**
     * @dev Executes a token swap on Uniswap V2 from tokens to ETH.
     */
    function swapTokensForEth() public {
        if (!canSwapBackstop()) {
            revert LavaSwapNotReady(backstopFundingAccumulated, block.timestamp - lastTransferTime);
        }

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswap2Router.WETH();

        lastTransferTime = block.timestamp;
        if (nbrSwaps < STEPS_CAP) {
            nbrSwaps += 1;
        }

        uint256 tokenAmount = backstopFundingAccumulated;
        backstopFundingAccumulated = 0;
        _approve(address(this), address(uniswap2Router), tokenAmount);

        uniswap2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            deltaSwapAmount * 90 / 100,
            path,
            address(this),
            lastTransferTime + 1 hours
        );

        emit ContributionsSentToRouter(address(uniswap2Router), tokenAmount);
    }

    /**
    * @dev Allows owner to update the parameters of the contract.
    * @param buyContribPer10000 The percentage of the transaction fee for buy transactions.
    * @param sellContribPer10000 The percentage of the transaction fee for sell transactions.
    * @param transferContribPer10000 The percentage of the transaction fee for transfer transactions.
    * @param swapDeltaThreshold The minimum amount of tokens to accumulate before triggering a swap.
     */
    function updateParameters(uint8 buyContribPer10000, uint8 sellContribPer10000, uint8 transferContribPer10000, uint256 swapDeltaThreshold) public onlyOwner {
        if (buyContribPer10000 > MAX_CONTRIBUTION_PER_10000 || sellContribPer10000 > MAX_CONTRIBUTION_PER_10000 || transferContribPer10000 > MAX_CONTRIBUTION_PER_10000) {
            revert LavaContributionTooHigh(buyContribPer10000, sellContribPer10000, transferContribPer10000);
        }
        if (swapDeltaThreshold > MAX_DELTA_SWAP_AMOUNT) {
            revert LavaSwapDeltaTooHigh(swapDeltaThreshold);
        }
        buyContributionPer10000 = buyContribPer10000;
        sellContributionPer10000 = sellContribPer10000;
        transferContributionPer10000 = transferContribPer10000;
        deltaSwapAmount = swapDeltaThreshold;

        emit ParametersUpdated(buyContribPer10000, sellContribPer10000, transferContribPer10000, swapDeltaThreshold);
    }

    /**
     * @dev Fallback function to accept ETH directly into the backstop pool.
     */
    fallback() external payable {
        usableBackstopPool += msg.value;
        emit LavaFundsReceived(_msgSender(), msg.value);
    }

    /**
     * @dev Receive function to accept ETH directly into the backstop pool when sent without data.
     */
    receive() external payable {
        usableBackstopPool += msg.value;
        emit LavaFundsReceived(_msgSender(), msg.value);
    }
}
