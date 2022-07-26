## Understanding Uniswap V2 Contracts

Uniswap is one of the pioneers of Decentralized finance offering an Automated-Market-Maker through its pools.
Automated Market Maker (AMM) meaning we do not need an external third party to mediate buying and selling.
It does the required tasks with the help of a Mathematical function x*y = k  which dictates price of an asset relative
to another asset.
Anyone one can go and form a pool of two assets containing X amount of token A and Y amount of token B.
Price is calculated relative to the other asset, meaning the denominated is the other asset. And this is done simply by dividing
amounts of both the assets. That's it.
x*y = K  is a form of CFMM ( Constant function Market Maker ). K being the constant means that x and y will change after each trade and keeping their product constant.
This offers a total independence from the actual market prices since we are not feeding any data from the market. This offers an opportunity
of arbitrage and frequent arbitrage keeps the price in check.


Uniswap V2 is a binary contract system. The whole codebase is divided into Core and Periphery. 
These are the core contracts:

1. UniswapV2ERC20.sol 
2. UniswapV2Factory.sol
3. UniswapV2Pair.sol


*UniswapV2ERC20.sol*
