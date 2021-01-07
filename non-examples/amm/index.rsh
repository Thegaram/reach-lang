'reach 0.1';

const [isSwapTrade, SWAP_IN, SWAP_OUT] = makeEnum(2);
const [isProviderAction, DEPOSIT, WITHDRAW] = makeEnum(2);

const Swap = Object({
  tokenInFrom: Address,
  tokenInAmt: UInt,
  tokenOutTo: Address,
  tokenOutAt: UInt,
  maxPrice: UInt,
});

const PARTICIPANTS = [
  // XXX: Feature - Better specification of entities
  Participant('Admin', {
    formulaValuation: Null, // Fun([UInt, UInt], UInt)?
    active: Bool,
    shouldClosePool: Fun([], Bool),
  }),
  Class('Provider', {
    shouldDepositOrWithdraw: Fun([], Bool),
    getAction: Fun([], Tuple(UInt, UInt)),
  }),
  Class('Trader', {
    shouldTrade: Fun([], Bool),
    getTrade: Fun([], Tuple(UInt, Swap)),
  }),
  // XXX: Feature - Non-network token consumption
  Token('TokA', tokBWeight),
  Token('TokB', tokAWeight),
];

const BalanceInfo = Object({
  tok: Token,
  tokBalance: UInt,
  tokWeight: UInt,
});

export const main =
  Reach.App(
    {},
    PARTICIPANTS,
    (Admin, Provider, Trader) => {
      // What are parameters?
      Admin.only(() => {
        const formulaValuation = declassify(interact.formulaValuation);
        const active = declassify(interact.active);
      });
      Admin.publish(formulaValuation, active);

      const initialMarket = array(BalanceInfo, [
        { tok: tokA, tokBalance: 0, tokWeight: TokAWeight },
        { tok: tokB, tokBalance: 0, tokWeight: TokBWeight },
      ]);
      // XXX: Feature - Map container
      const initialPool = new Map(Address); // Address -> balance

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
                case DEPOSIT: {

                }
                case WITHDRAW: {

                }
              }
            }))
          .case(
            Trader,
            (() => ({
              msg: declassify(interact.getTrade()),
              when: declassify(interact.shouldMakeTrade()),
            })),
            (([swapType, args]) => {
              switch (swapType) {
                case SWAP_IN: {

                }
                case SWAP_OUT: {

                }
              };
            }))
          .timeout(UInt.max, () => { // Never timeout?
            race(Admin, Provider, Trader).publish();
            return [ false, pool, market ]; })

      commit();
      exit();
    }
  );
