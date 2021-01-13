'reach 0.1';

const Swap = Object({
  amtIn: UInt,
  amtInTok: UInt,
  amtOutTok: UInt,
});

const Deposit = Object({
  // XXX Feature: Need to access compile time arg
  // of how many tokens will be in market
  amtIns: Array(UInt, argv(1)),
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
    getDeposit: Fun([], Deposit),
  }),
  Class('Trader', {
    shouldTrade: Fun([], Bool),
    getTrade: Fun([], Swap),
  }),

  // XXX: Feature - Non-network token consumption
  // Token, Token       // Uniswap, specify 2
  Tokens,               // Generalized array of N tokens

  // XXX: Feature - Token container (map-container-that-is-a-token)
  // JM: Because of Algorand, we'll need to have a built-in notion of a map-container-that-is-a-token and this would be an argument to Reach.DApp
  MintedToken,
];

const getReserves = (market) =>
  market.tokens.map(t => t.balance);

const swap = (amtIns, amtOuts, to, tokens, market) => {
  // Assert at least 1 token out
  assert(amtOuts.any(amt => amt > 0), "Insufficient amount out");

  // Reserves is how many of each token is in pool.
  const startingReserves = getReserves(market);

  // Assert amount outs are less than reserves of each token
  Array.zip(startingReserves, amtOuts).forEach(([reserve, amtOut]) =>
    assert(amtOut < reserve, "Insufficient liquidity"));

  // Optimistically transfer the given amount of tokens
  // XXX: Feature - Pay in a specified token
  Array.zip(tokens, amtOuts)
    .forEach(([ tok, amtOut ]) =>
      transfer(amtOut).currency(tok).to(to));

  // Update market reserve balances.
  const updatedMarket = updateMarket(market, amtIns, amtOuts);
  // Get new reserves & actual balances
  const reserves = getReserves(updatedMarket);
  const balances = tokens.map(balanceOf);

  // Ensure the balances are at least as much as the reserves
  // XXX: Stdlib Fn - Product of array
  assert(balances.product() >= reserves.product(), "K");

  // Update cumulative price if tracking
  return updatedMarket;
};

// Take into account .3% fee
const getAmountOut = (amtIn, reserveIn, reserveOut) => {
  // Calculate what amountIn was prior to fees
  const adjustedIn = amtIn * 997 / 1000;
  const reserveProduct = reserveOut * reserveIn;
  const adjustedReserveIn = reserveIn + adjustedIn;
  return reserveOut - (reserveProduct / adjustedReserveIn);
};


/**
 * Updates the balance of each market token by adding the
 * corresponding index of `amtIns`, and subtracting
 * the corresponding index of `amtOuts`.
 */
const updateMarket = (market, amtIns, amtOuts) => ({
  params: market.params,
  tokens: Array.zip( market.tokens, Array.zip(amtIns, amtOuts) )
    .map(([ tp, [ amtIn, amtOut ] ]) =>
      ({ balance: tp.balance + amtIn - amtOut })),
});

export const main =
  Reach.App(
    {},
    PARTICIPANTS,
    // tokens will only be used to grab balances, transfer, pay
    (Admin, Provider, Trader, tokens, initialPool) => {

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
        tokens: Array.replicate(tokens.length, { balance: 0 }),
      };

      const mtArr = Array.replicate(tokens.length, 0);

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
              when: declassify(interact.wantsToWithdraw()),
            })),
            (() => {
              // Get the liquidity share for Provider
              const liquidity = pool.balanceOf(this);

              // Balances have fees incorporated
              const balances = tokens.map(balanceOf);

              // The amount of each token in the reserve to return to Provider
              const amtOuts = balances.map(bal => liquidity * bal / pool.totalSupply());

              // Payout provider
              Array.zip(tokens, amtOuts)
                .forEach(([ tok, amtOut ]) =>
                  transfer(amtOut).currency(tok).to(this));

              const updatedMarket = updateMarket(market, mtArr, amtOuts);

              /*
              XXX Feature: MintedToken.burn which behind the scenes does:
                  balanceOf[from] = balanceOf[from] - value;
                  totalSupply = totalSupply - value;
              */
              const updatedPool = pool.burn(this, liquidity);

              return [ true, updatedPool, updatedMarket ];
            }))
          .case(
            Provider,
            (() => ({
              msg: declassify(interact.getDeposit()),
              when: declassify(interact.wantsToDeposit()),
            })),
            // XXX Feature: allow PAY_EXPR to make multiple payments in different currencies
            (({ amtIns }) => Array.zip(tokens, amtIns))
            (({ amtIns }) => {

              const startingReserves = getReserves(market);

              // This will happen after payment :/
              // Could convert into if (chk) { return payment & fail; }
              assert(
                amtIns.div() == startingReserves.div(),
                "Must deposit pair tokens proportional to the current price");

              const updatedMarket = updateMarket(market, amtIns, mtArr);

              /*
                Mint liquidity tokens
                   If first deposit:
                     use geometric mean of inputs
                   Otherwise:
                     calculate the % of pool provided
              */
              const minted = pool.totalSupply() == 0
                // XXX Stdlib Fn: Square root
                ? sqrt(amtIns.product())
                // XXX Stdlib Fn: Average of int array
                : Array.zip(startingReserves, amtIns)
                  .map(([ sIn, amtIn ]) => (amtIn / sIn) * pool.totalSupply())
                  .average();

              /*
              XXX Feature: MintedToken.mint which behind the scenes does:
                  totalSupply = totalSupply + value;
                  balanceOf[to] = balanceOf[to] + value;
              */
              const updatedPool = pool.mint(this, minted);

              return [ true, updatedPool, updatedMarket ];
            }))
          .case(
            Trader,
            (() => ({
              msg: declassify(interact.getTrade()),
              when: declassify(interact.shouldMakeTrade()),
            })),
            // Amt in has fees incorporated into it
            (({ amtIn, amtInTok }) => [ [ amtIn, amtInTok ] ]),
            (({ amtIn, amtInTok }) => {
              // Calculate amount out
              const reserveIn  = market.tokens[amtInTok].balance;
              const reserveOut = market.tokens[amtOutTok].balance;
              const amtOut  = getAmountOut(amtIn, reserveIn, reserveOut);

              // Get all outs and ins for tokens
              const amtOuts = mtArr.set(amtOutTok, amtOut);
              const amtIns  = mtArr.set(amtInTok, amtIn);

              const to = this;
              const updatedMarket = swap(amtIns, amtOuts, to, tokens, market);

              return [ true, pool, updatedMarket ];
            }))
          .timeout(UInt.max, () => { // Never timeout
            race(Admin, Provider, Trader).publish();
            return [ false, pool, market ]; })

      commit();
      exit();
    }
  );
