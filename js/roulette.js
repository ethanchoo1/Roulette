(function (root, factory) {
  const engine = factory();
  if (typeof module === 'object' && module.exports) module.exports = engine;
  else root.Roulette = engine;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const RED_NUMBERS = new Set([1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
  const WHEEL_ORDER = [32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26];
  const EVEN_TYPES = new Set(['red','black','odd','even','low','high']);
  const NUMBER_TYPES = new Set(['straight','split','street','corner','six-line','dozen','column',...EVEN_TYPES]);
  const sorted = values => values.slice().sort((a,b) => a-b);
  const sameNumbers = (a,b) => a.length === b.length && sorted(a).every((n,i) => n === sorted(b)[i]);

  function numbersFor(type, value) {
    if (type === 'straight') return [Number(value)];
    if (type === 'dozen') { const start = (Number(value)-1)*12+1; return Array.from({length:12},(_,i)=>start+i); }
    if (type === 'column') { const col=Number(value); return Array.from({length:12},(_,i)=>col+i*3); }
    if (EVEN_TYPES.has(type)) {
      if (type==='red') return Array.from(RED_NUMBERS);
      if (type==='black') return Array.from({length:36},(_,i)=>i+1).filter(n=>!RED_NUMBERS.has(n));
      if (type==='odd') return Array.from({length:18},(_,i)=>i*2+1);
      if (type==='even') return Array.from({length:18},(_,i)=>(i+1)*2);
      if (type==='low') return Array.from({length:18},(_,i)=>i+1);
      return Array.from({length:18},(_,i)=>i+19);
    }
    throw new Error('Numbers must be supplied for this bet type');
  }

  function boardPosition(n) {
    if (!Number.isInteger(n) || n<1 || n>36) return null;
    return { col:Math.floor((n-1)/3), row:2-((n-1)%3) };
  }
  function areAdjacent(a,b) {
    const p=boardPosition(a),q=boardPosition(b);
    return !!p && !!q && Math.abs(p.col-q.col)+Math.abs(p.row-q.row)===1;
  }
  function isStreet(nums) {
    return nums.length===3 && Array.from({length:12},(_,col)=>[col*3+1,col*3+2,col*3+3]).some(row=>sameNumbers(nums,row));
  }
  function isCorner(nums) {
    if(nums.length!==4)return false;
    for(let col=0;col<11;col++)for(let low=1;low<=2;low++)if(sameNumbers(nums,[col*3+low,col*3+low+1,(col+1)*3+low,(col+1)*3+low+1]))return true;
    return false;
  }
  function isSixLine(nums) {
    if(nums.length!==6)return false;
    for(let col=0;col<11;col++)if(sameNumbers(nums,Array.from({length:6},(_,i)=>col*3+i+1)))return true;
    return false;
  }
  function validateBet(input) {
    if(!input || !NUMBER_TYPES.has(input.type))throw new Error('Unknown bet type');
    if(!Number.isSafeInteger(input.amount)||input.amount<=0)throw new Error('Bet amount must be a positive whole number');
    let nums=(input.numbers || numbersFor(input.type,input.value)).map(Number);
    if(nums.some(n=>!Number.isInteger(n)||n<1||n>36)||new Set(nums).size!==nums.length)throw new Error('Bet numbers must be unique values from 1 to 36');
    const count={straight:1,split:2,street:3,corner:4,'six-line':6,dozen:12,column:12}[input.type];
    if(count && nums.length!==count)throw new Error('Incorrect number count for bet type');
    const valid = input.type==='straight' || (input.type==='split' && areAdjacent(...nums)) || (input.type==='street' && isStreet(nums)) || (input.type==='corner' && isCorner(nums)) || (input.type==='six-line' && isSixLine(nums)) || (input.type==='dozen' && [1,2,3].includes(Number(input.value)) && sameNumbers(nums,numbersFor('dozen',input.value))) || (input.type==='column' && [1,2,3].includes(Number(input.value)) && sameNumbers(nums,numbersFor('column',input.value))) || (EVEN_TYPES.has(input.type) && sameNumbers(nums,numbersFor(input.type)));
    if(!valid)throw new Error('Invalid number combination for '+input.type);
    const bet={type:input.type,numbers:sorted(nums),amount:input.amount};
    if(input.type==='dozen'||input.type==='column')bet.value=Number(input.value);
    return bet;
  }
  const NET_ODDS={straight:35,split:17,street:11,corner:8,'six-line':5,dozen:2,column:2,red:1,black:1,odd:1,even:1,low:1,high:1};
  function payoutFor(bet,result) {
    const valid=validateBet(bet);
    if(!Number.isInteger(result)||result<1||result>36)throw new Error('Result must be from 1 to 36');
    return valid.numbers.includes(result) ? valid.amount*(NET_ODDS[valid.type]+1) : 0;
  }
  function settleBets(bets,result) { return bets.reduce((total,bet)=>total+payoutFor(bet,result),0); }
  function makeBetId(bet) { const valid=validateBet(bet); return valid.type+':'+valid.numbers.join('-'); }
  return {RED_NUMBERS,WHEEL_ORDER,NET_ODDS,numbersFor,boardPosition,areAdjacent,validateBet,payoutFor,settleBets,makeBetId};
});
