pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    // The number of liquidity tokens locked permanently to address(0) to prevent the price of minimum liquidity pool share to rise too much. (ref sec 3.4)
    uint public constant MINIMUM_LIQUIDITY = 10**3;

    // Get the first 4 bytes of the `transfer` function calldata of UniswapV2ERC20 token, used as function selector
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory; // `UniswapV2Factory.sol address
    address public token0;  // token0 address
    address public token1;  // token1 address

    uint112 private reserve0;           // token0 cached reserve in the contract updated after each tx (ref sec 2.2)
    uint112 private reserve1;           // token1 cached reserve in the contract updated after each tx (ref sec 2.2)
    uint32  private blockTimestampLast; // timestamp of the last mined block

    /**(ref sec 2.2) */
    // accumulated_price_0 = cumulative sum of prices of token0 at the beginning of each block in which someone interacts with the contract
    // accumulated_price_1 = cumulative sum of prices of token1 at the beginning of each block in which someone interacts with the contract

    // accumulated_price_0 weighted by the time passed since the last block in which it was updated.
    uint public price0CumulativeLast;
    // accumulated_price_1 weighted by the time passed since the last block in which it was updated.
    uint public price1CumulativeLast; 

    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // `lock` to prevent reentancy to all public state changing functions. (ref sec 3.3)
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**Returns value of reserve0, reserve1 and blockTimestampLast */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**Safe implementation of `transfer` method of UniswapV2ERC20 token interpreting no return value as success
    (Ref sec 3.3)
    */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /**Factory contract gets set as `factory` on generating this pair contract */
    constructor() public {
        factory = msg.sender;
    }

    // Called once by the factory contract at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /** Gets called after each transaction to update last block timestamp, cached reserves and, on the first call per block, price accumulators.
    Input: current contract token0 balance, current contract token1 balance, cached token0 balance, cached token1 balance.
    Output: None
    ref sec 2.2
    */
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);  // current block timestamp
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // price_CumulativeLast = price_CumulativeLast + current_token_price*timeElapsed (ref sec 2.2)
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        // Update cached reserves
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /**  If fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    Gets called before any liquidity event(mint/burn) to mint 0.05% of the protocol fee to `feeTo` account.
    (refer sec 2.4)
    */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // Fetch the `feeTo` address from `UniswapV2Factory` contract
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // (reserve0*reserve1)
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // Equivalent number of UNI tokens to be minted to `feeTo` account (refer sec 2.4)
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
    This function gets called when a liquidity provider deposits some liquidity in the pool and the corresponding UNI tokens are minted into his account.
    Input: address of the LP
    Output: the number of UNI tokens minted to `to` LP
    (ref sec 3.4)
    */
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // token0 balance in contract after liquidity deposit
        uint balance0 = IERC20(token0).balanceOf(address(this)); 
        // token1 balance in contract after liquidity deposit
        uint balance1 = IERC20(token1).balanceOf(address(this)); 
        uint amount0 = balance0.sub(_reserve0); // number of token0 deposited by LP
        uint amount1 = balance1.sub(_reserve1); // number of token1 deposited by LP

        // Mint the protocol fee into `feeTo` account before the liquidity event
        bool feeOn = _mintFee(_reserve0, _reserve1);

        // Number of UNI tokens minted till now 
        uint _totalSupply = totalSupply;
        
        // Number of UNI tokens to be minted into the LP's account (Ref sec 3.4)
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity); 
        
        // Updating the token cached reserves, blocktimestamp and price accumulator after the tx
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // upadating kLast (reserve0 and reserve1 are up-to-date)
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
    This function gets called when a liquidity provider burns the liquidity tokens held by him and the equivalent token0 and token1 are minted into his account.
    Input: address of the LP
    Output: the number of token0 and token1 minted to `to` LP
    */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));// number of token0 held in the contract
        uint balance1 = IERC20(_token1).balanceOf(address(this));// number of token1 held in the contract

        // Number of UNI tokens held in the contract that will be burned
        uint liquidity = balanceOf[address(this)];               

        // Mint the protocol fee into `feeTo` account before the liquidity event
        bool feeOn = _mintFee(_reserve0, _reserve1);

        // Number of UNI tokens minted till now
        uint _totalSupply = totalSupply;

        amount0 = liquidity.mul(balance0) / _totalSupply; // number of token0 that'll be withdrawn from contract
        amount1 = liquidity.mul(balance1) / _totalSupply; // number of token1 that'll be withdrawn from contract

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        // Transfer token0,1 to `to`
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        // Updated balance of token0,1 in the contract
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        // Updating the token cached reserves, blocktimestamp and price accumulator after the tx
        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
    This function gets called when a user swaps token0, token1
    Input: number of token0, token1 the user wants in return, address, user-specified callback
    Output: None
    Implements FlashSwaps: allows a user to receive and use an asset before paying for it as long as they make the payment within the same atomic transaction.
    Ref sec 2.3, 3.2.1
    */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');

        // step1: optimistically tranfer tokens
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

        // step2: make call to user specified callback contract and enforcing invariant
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

        // token0,1 balance in the contract after giving out tokens and executing callback
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }

        // The amount of token0,1 the user has returned back
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        // step3: Enforcing invariant
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors (refer sec 3.2.1)
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        
        // Updating the token cached reserves, blocktimestamp and price accumulator after the tx
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    // (ref sec 3.2.2)
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    // (ref sec 3.2.2)
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
