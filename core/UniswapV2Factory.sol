pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    // Uniswap v2 address  to which 0.05% of the protocol fees is sent (ref sec 2.4)
    address public feeTo;

    //Address that is allowed to set the `feeTo` address
    address public feeToSetter;

    // [token0_address][token1_address] => [pair_contract_address]
    mapping(address => mapping(address => address)) public getPair;

    // Array of contract addresses of all token pairs
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    /* Constructor sets the `feeToSetter` */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter; 
    }

    /** Returns the number of pair contracts ie. the length of the `allPairs` array  */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /**
    This function takes in token address of two address, generates a `UniswapV2pair` contract and returns the address of the generated contract.
    Requirements: the two addresses must be non-zero and distinct 
    Input: address of tokenA, address of tokenB
    Output: address of generated Uniswapv2Pair contract
    */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient

        // fetching bytecode of `UniswapV2Pair` contract
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // Using `create2` opcode to generate a pair contract with deterministic address
        // (ref sec 3.6)
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // Initialising the pair contract by calling the `initialize` method
        IUniswapV2Pair(pair).initialize(token0, token1);

        // Populating `getPair` mapping and `allPairs` array
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
    Sets the `feeTo` address
    Requirement: Only `feeToSetter` can call this function
    Input: new `_feeTo` address
    Output: None
    */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
    Sets the `feeToSetter` address
    Requirement: Only `feeToSetter` can call this function
    Input: new `_feeToSetter` address
    Output: None
    */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
