'reach 0.1';

export const main = Reach.App(
  { deployMode: 'firstMsg' },
  [['Alice', { amt : UInt,
               pass: UInt }],
   ['Bob', { getPass: Fun([], UInt) }] ],
  (Alice, Bob) => {
    Alice.only(() => {
      const [ amt, passDigest ] =
            declassify([ interact.amt,
                         digest(interact.pass) ]); });
    Alice.publish(passDigest, amt)
      .pay(amt);
    commit();

    unknowable(Bob, Alice(interact.pass));
    Bob.only(() => {
      const pass = declassify(interact.getPass());
      assume( passDigest == digest(pass) ); });
    Bob.publish(pass);
    require( passDigest == digest(pass) );
    transfer(amt).to(Bob);
    commit();

    exit(); } );
