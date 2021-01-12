'reach 0.1';

const [isProviderAction, DEPOSIT, WITHDRAW] = makeEnum(2);

const Swap = Object({
  amtIn: UInt,
  amtInTok: Token,
});

const PARTICIPANTS = [
  // XXX: Feature - Better specification of entities
  Participant('Admin', {
    formulaValuation: UInt, // k
    active: Bool,
    shouldClosePool: Fun([], Bool),
  }),
  Class('Provider', {
    shouldDepositOrWithdraw: Fun([], Bool),
    getAction: Fun([], Tuple(UInt, UInt)),
  }),
  Class('Trader', {
    shouldTrade: Fun([], Bool),
    getTrade: Fun([], Swap),
  }),
  // XXX: Feature - Non-network token consumption
  Token('TokA', tokBWeight),
  Token('TokB', tokAWeight),
];

// https://github.com/Uniswap/uniswap-v2-core/blob/4dd59067c76dea4a0e8e4bfdda41877a6b16dedc/contracts/UniswapV2Pair.sol#L73-L86
const update = (pool, balances, tokens) => {
  // Update cumulative price if tracking

  // Update reserve of tokens in pool
  Array.zip(balances, tokens)
    .map(([ bal, t ]) => { pool[t] = bal; });
}

// tokens must be transferred to pairs before swap is called
// https://github.com/Uniswap/uniswap-v2-core/blob/4dd59067c76dea4a0e8e4bfdda41877a6b16dedc/contracts/UniswapV2Pair.sol#L159-L183
const swap = (amtOuts, to, Tokens, pool, market) => {
  // Assert at least 1 token out
  assert(amtOuts.any(amt => amt > 0), "Insufficient amount out");

  // Reserves is how many of each token is in pool.
  const reserves = Tokens.map(t => pool[t]);

  // Assert amount outs are less than reserves of each token
  Array.zip(reserves, amtOuts).forEach(([reserve, amtOut]) =>
    assert(amtOut < reserve, "Insufficient liquidity"));

  // Optimistically transfer the given amount of tokens
  // XXX: Feature - Pay in a specified token
  Array.zip(Tokens, amtOuts).forEach(([t, amtOut]) =>
    pay(t, amtOut).to(to));

  const balances = market.tokens.map(t => t.balance);

  const amtIns = Array.iota(Tokens.length)
    .map(i => [ balances[i], reserves[i], amtOuts[i] ])
    .map(([ bal, res, amtOut]) =>
      bal > res - amtOut ? bal - (res - amtOut) : 0);

  assert(amtIns.any(amt => amt > 0), "Insufficient input amount");

  // Adjustment for fees:  trading fee is applied by reducing the
  // amount paid into the contract by 0.3% before enforcing the
  // constant-product invariant.
  const adjustedBalances = Array.zip(balances, amtIns)
    .map(([ bal, amtIn ]) => bal * 1000 - amtIn * 3);

  // XXX: Stdlib Fn - Product of array
  assert(adjustedBalances.product() >= reserves.product() * 1000000, "K");

  update(pool, balances, tokens);

  return [ true, pool, market ];
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
    (Admin, Provider, Trader) => {

      Admin.only(() => {
        const formulaValuation = declassify(interact.formulaValuation);
        const active = declassify(interact.active);
      });
      Admin.publish(formulaValuation, active);

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
        tokens: array(Token, [TokA, TokB]).map(tok =>
          ({ tok: tok, balance: 0 })),
      };

      // XXX: Feature - Map container
      const initialPool = new Map(Address); // Address (Token) -> balance

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
              msg: declassify(interact.getAction()),
              when: declassify(interact.shouldDepositOrWithdraw()),
            })),
            (([action, amt]) => {
              switch (action) {
                case DEPOSIT: { }
                case WITHDRAW: { }
              }
            }))
          .case(
            Trader,
            (() => ({
              msg: declassify(interact.getTrade()),
              when: declassify(interact.shouldMakeTrade()),
            })),
            (({ amtIn, amtInTok }) => {
              // Calculate amount out
              const isTokA = amtInTok == TokA;
              const [ reserveIn, reserveOut ]  =
                isTokA
                  ? [ pool[TokA], pool[TokB] ]
                  : [ pool[TokB], pool[TokA] ];
              const amtOut  = getAmountOut(amtIn, reserveIn, reserveOut);
              const amtOuts = array(UInt, isTokA ? [amtOut, 0] : [0, amtOut]);

              // Trader pays amount in
              Trader.pay(amtInTok, amtIn);

              // Update market token balance
              const amtIns = array(UInt, isTokA ? [amtIn, 0] : [0, amtIn]);
              Array.zip(market.tokens, amtIns)
                .map(([ mt, amtIn ]) => mt.balance += amtIn);
              Array.zip(market.tokens, amtOuts)
                .map(([ mt, amtOut ]) => mt.balance -= amtOut);

              const to = this;
              return swap(amtOuts, to, Tokens, pool, market);
            }))
          .timeout(UInt.max, () => { // Never timeout?
            race(Admin, Provider, Trader).publish();
            return [ false, pool, market ]; })

      commit();
      exit();
    }
  );
