'reach 0.1';

const Swap = Object({
  amtIn: UInt,
  amtInTok: UInt,
  amtOutTok: UInt,
});

const PARTICIPANTS = [
  // XXX: Feature - Better specification of entities
  Participant('Admin', {
    formulaValuation: UInt, // k
    shouldClosePool: Fun([], Bool),
  }),
  Class('Provider', {
    wantsToDeposit: Fun([], Bool),
    wantsToWithdraw: Fun([], Bool),
    getDeposit: Fun([], UInt),
    getWithdrawal: Fun([], UInt),
  }),
  Class('Trader', {
    shouldTrade: Fun([], Bool),
    getTrade: Fun([], Swap),
  }),

  // XXX: Feature - Non-network token consumption
  Token,
  Token,
  // XXX: Feature - Token container (map-container-that-is-a-token)
  // JM: Because of Algorand, we'll need to have a built-in notion of a map-container-that-is-a-token and this would be an argument to Reach.DApp
  MintedToken,
];

// https://github.com/Uniswap/uniswap-v2-core/blob/4dd59067c76dea4a0e8e4bfdda41877a6b16dedc/contracts/UniswapV2Pair.sol#L73-L86
const update = (balances, tokens) => {
  // Update cumulative price if tracking
}

// tokens must be transferred to pairs before swap is called
// https://github.com/Uniswap/uniswap-v2-core/blob/4dd59067c76dea4a0e8e4bfdda41877a6b16dedc/contracts/UniswapV2Pair.sol#L159-L183
const swap = (amtOuts, to, tokens, market) => {
  // Assert at least 1 token out
  assert(amtOuts.any(amt => amt > 0), "Insufficient amount out");

  // Reserves is how many of each token is in pool.
  const reserves = market.tokens.map(t => t.balance);

  // Assert amount outs are less than reserves of each token
  Array.zip(reserves, amtOuts).forEach(([reserve, amtOut]) =>
    assert(amtOut < reserve, "Insufficient liquidity"));

  // Optimistically transfer the given amount of tokens
  // XXX: Feature - Pay in a specified token
  Array.zip(tokens, amtOuts)
    .forEach(([ tok, amtOut ]) =>
      transfer(amtOut).currency(tok).to(to));

  // This gets the balance of the specified token in the contract
  const balances = tokens.map(balanceOf);

  // XXX: Stdlib Fn - Product of array
  assert(balances.product() >= reserves.map(b => b * 1000).product(), "K");

  // update(balances, tokens);
};

// Uniswap function for 2 tokens. Take into account .3% fee
// https://github.com/Uniswap/uniswap-api/blob/8bcfc4591ba8c5fb2d79e2399259bdee980e81bb/src/utils/computeBidsAsks.ts#L3-L16
const getAmountOut = (amtIn, rIn, rOut) => {
  const reserveIn = rIn * 1000;
  const reserveOut = rOut * 1000;
  const adjustedIn = amtIn * 997;
  const reserveProduct = reserveOut * reserveIn;
  const adjustedReserveIn = reserveIn * adjustedIn;
  return reserveOut - (reserveProduct / adjustedReserveIn);
}

export const main =
  Reach.App(
    {},
    PARTICIPANTS,
    (Admin, Provider, Trader, TokA, TokB, initialPool) => {

      Admin.only(() => {
        const formulaValuation = declassify(interact.formulaValuation);
      });
      Admin.publish(formulaValuation);

      /*
        market : Object({
          params: ConstraintParams,
          tokens: Array(HowMany, TokenParams)
        })

        For UniSwap:
          ConstraintParams  = UInt // k
          TokenParams       = UInt // balance
      */
      const initialMarket = {
        params: formulaValuation,
        tokens: Array.replicate(2, { balance: 0 }),
      };

      // Produces pool tokens   (1 type)
      // Consumes market tokens (n type)
      const [ alive, pool, market ] =
        parallel_reduce([ true, initialPool, initialMarket ])
          .while(alive)
          .invariant(true)
          .case(
            Admin,
            (() => ({
              when: declassify(interact.shouldClosePool())
            })),
            (() => {
              return [ false, pool, market ]; })
            )
          .case(
            Provider,
            (() => ({
              msg: declassify(interact.getWithdrawal()),
              when: declassify(interact.wantsToWithdraw()),
            })),
            ((args) => {}))
          .case(
            Provider,
            (() => ({
              msg: declassify(interact.getDeposit()),
              when: declassify(interact.wantsToDeposit()),
            })),
            ((args) => {}))
          .case(
            Trader,
            (() => ({
              msg: declassify(interact.getTrade()),
              when: declassify(interact.shouldMakeTrade()),
            })),
            // XXX Feature - allow PAY_EXPR to additionally capture Token type for payment
            (({ amtIn, amtInTok }) => [ amtIn, amtInTok ]),
            (({ amtIn, amtInTok }) => {
              // Calculate amount out
              const reserveIn  = market.tokens[amtInTok].balance;
              const reserveOut = market.tokens[amtOutTok].balance;
              const amtOut  = getAmountOut(amtIn, reserveIn, reserveOut);

              // Get all outs and ins for tokens
              const mtArr = Array.replicate(market.tokens.length, 0);
              const amtOuts = mtArr.set(amtOutTok, amtOut);
              const amtIns  = mtArr.set(amtInTok, amtIn);

              // Update market token balance
              const updatedMarket = {
                params: market.params,
                tokens: Array.zip( market.tokens, Array.zip(amtIns, amtOuts) )
                  .map(([ tp, [amtIn, amtOut] ]) =>
                    ({ balance: tp.balance + amtIn - amtOut })),
              };

              const to = this;
              swap(amtOuts, to, [tokA, tokB], updatedMarket);
              return [ true, pool, updatedMarket ];
            }))
          // JM: Never time out
          .timeout(UInt.max, () => { // Never timeout?
            race(Admin, Provider, Trader).publish();
            return [ false, pool, market ]; })

      commit();
      exit();
    }
  );
