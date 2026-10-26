const {RED_NUMBERS,WHEEL_ORDER,numbersFor,boardPosition,validateBet,settleBets,makeBetId}=Roulette;
const state={round:4,status:'waiting',result:17,activeTeam:0,chipValue:25,teams:[
  {name:'BLUE',funds:1240,players:5,bets:[]},{name:'RED',funds:920,players:4,bets:[]},{name:'GREEN',funds:1350,players:6,bets:[]},{name:'GOLD',funds:1090,players:3,bets:[]}],
  activity:[['Sarah','joined BLUE team'],['Steve','joined BLUE team'],['Mike','joined BLUE team']]};
const $=id=>document.getElementById(id), money=n=>'$'+n.toLocaleString();
const team=()=>state.teams[state.activeTeam];
let heldBalanceKey=null,heldBalances=null,lastReleasedBalanceKey=null;
const balanceKey=t=>t.id??t.name;
function visibleFunds(t){return heldBalances?.has(balanceKey(t))?heldBalances.get(balanceKey(t)):t.funds}
function holdSettlementBalances(resultKey){if(resultKey===lastReleasedBalanceKey||heldBalanceKey===resultKey)return;heldBalanceKey=resultKey;heldBalances=new Map(state.teams.map(t=>[balanceKey(t),t.funds]))}
function releaseSettlementBalances(resultKey){if(!heldBalances||heldBalanceKey!==resultKey)return;heldBalances=null;heldBalanceKey=null;lastReleasedBalanceKey=resultKey;renderBets();renderTeams();renderScore()}
const CHIP_VALUES=[1,5,25,100,500,1000];
let timerSeconds=60,timerHandle=null;
const BET_LABEL={straight:'Straight',split:'Split',street:'Street',corner:'Corner','six-line':'Six-line',dozen:'Dozen',column:'Column',red:'Red',black:'Black',odd:'Odd',even:'Even',low:'1–18',high:'19–36'};
function labelBet(bet){return `${BET_LABEL[bet.type]} ${bet.numbers.join(', ')}`}
function renderChipTray(){const tray=$('chipTray');tray.replaceChildren();for(const value of CHIP_VALUES){const button=document.createElement('button');button.type='button';button.className=`chipOption chip${value}`;button.textContent='$'+value.toLocaleString();button.setAttribute('aria-label',`Select ${money(value)} chip`);button.setAttribute('aria-pressed',String(state.chipValue===value));button.dataset.value=value;button.addEventListener('click',()=>{state.chipValue=value;tray.querySelectorAll('.chipOption').forEach(chip=>chip.setAttribute('aria-pressed',String(Number(chip.dataset.value)===value)));$('betHint').textContent=`Selected chip: ${money(value)}. Choose a number or bet area.`;renderBets()});tray.append(button)}$('betHint').textContent=`Selected chip: ${money(state.chipValue)}. Choose a number or bet area.`}
function toast(s){$('toast').textContent=s;$('toast').classList.add('on');setTimeout(()=>$('toast').classList.remove('on'),1300)}
function renderBets(){const t=team();if(!t){$('balance').innerHTML=`${money(0)} <span>available</span>`;$('bets').innerHTML='<div class="emptyBets">No team selected. Join or create a team to play.</div>';return}const chip=state.chipValue||25;$('balance').innerHTML=`${money(visibleFunds(t))} <span>available</span>`;$('bets').innerHTML=t.bets.length?t.bets.map(b=>`<div class="betrow"><div>${labelBet(b)}</div><div>${money(b.amount)}</div><div class="step"><button class="mini" data-bet="${makeBetId(b)}" data-delta="-${Math.min(chip,b.amount)}" aria-label="Remove ${money(Math.min(chip,b.amount))}">−</button><button class="mini" data-bet="${makeBetId(b)}" data-delta="${chip}" aria-label="Add ${money(chip)}">+</button></div></div>`).join(''):'<div class="emptyBets">No bets placed</div>'; $('bets').querySelectorAll('button[data-bet]').forEach(b=>b.onclick=()=>changeBet(b.dataset.bet,Number(b.dataset.delta)))}
function renderActivity(){for(const id of ['activity','adminActivity']){const root=$(id);if(!root)continue;root.replaceChildren();const visible=state.activity.filter(item=>!(item.action==='payout'&&wheelMotion.settleTimer&&Number(item.roundNumber)===Number(state.round)));if(!visible.length){const empty=document.createElement('div');empty.className='emptyBets';empty.textContent='No recent activity';root.append(empty);continue}for(const item of visible){const row=document.createElement('div'),name=document.createElement('span'),detail=document.createElement('b');row.className='event';name.textContent=Array.isArray(item)?item[0]:item.actor;detail.textContent=Array.isArray(item)?item[1]:item.detail;row.append(name,detail);root.append(row)}}}
function renderTeams(){if(window.rouletteGame?.active)return window.rouletteGame.renderTeams();$('teamManage').innerHTML=state.teams.map((t,i)=>`<div class="manageRow"><input aria-label="Team name" value="${t.name}" onchange="state.teams[${i}].name=this.value;renderScore()"><input aria-label="Team funds" type="number" value="${visibleFunds(t)}" onchange="state.teams[${i}].funds=Math.max(0,+this.value);renderScore();if(${i}===state.activeTeam)renderBets()"><button class="btn" onclick="adjust(${i},100)">+$100</button></div>`).join('');renderScore()}
function renderScore(){const root=$('scoreboard');root.replaceChildren();for(const t of state.teams){const row=document.createElement('div'),name=document.createElement('b'),balance=document.createElement('strong');row.className='score';name.textContent=`${t.name} TEAM`;balance.textContent=money(visibleFunds(t));row.append(name,balance);root.append(row)}}
function recordActivity(message){state.activity.unshift([team().name,message]);state.activity=state.activity.slice(0,4);renderActivity()}
function changeBet(id,delta){if(window.rouletteGame?.active)return window.rouletteGame.changeBet(id,delta);if(state.status!=='betting')return toast('Bets are locked');const t=team(),index=t.bets.findIndex(b=>makeBetId(b)===id);if(index<0)return;if(delta>0&&t.funds<delta)return toast('Not enough team funds');const bet=t.bets[index],change=delta>0?delta:Math.min(state.chipValue,bet.amount);if(delta<0){bet.amount-=change;t.funds+=change;if(!bet.amount)t.bets.splice(index,1)}else{bet.amount+=change;t.funds-=change}recordActivity(`${delta>0?'increased':'reduced'} ${labelBet(bet)} by ${money(change)}`);renderBets();renderScore();renderBoard()}
function colorOf(n){return RED_NUMBERS.has(n)?'RED':'BLACK'}
function stablePocketOffset(key){let hash=2166136261;for(let i=0;i<key.length;i++){hash^=key.charCodeAt(i);hash=Math.imul(hash,16777619)}return ((hash>>>0)/4294967296)*9-4.5}
function compactBetAmount(amount){return new Intl.NumberFormat('en',{notation:'compact',maximumFractionDigits:1}).format(Number(amount)).replace(/K$/,'k')}
function setStatus(status){state.status=status;const labels={waiting:'Waiting for admin',betting:'Betting open',locked:'Bets locked',spinning:'Wheel spinning',result:'Result'}; $('statusText').textContent=labels[status];$('adminStatus').textContent=status.toUpperCase();$('lockBtn').textContent=status==='betting'?'LOCK BETS':'LOCK BETS';$('timerLabel').textContent=status==='betting'?'OPEN':status==='waiting'?'WAITING':'LOCKED';$('displayStatusText').textContent=labels[status].toUpperCase();renderTimer()}
function startBetting(){if(window.rouletteGame?.active)return window.rouletteGame.startBetting();if(state.status!=='waiting'&&state.status!=='result')return toast('Round is already active');clearWheelResult();startWheelSpin();setStatus('betting');timerSeconds=60;clearInterval(timerHandle);timerHandle=setInterval(()=>{timerSeconds--;renderTimer();if(timerSeconds<=0){clearInterval(timerHandle);lock();setTimeout(spin,450)}},1000);toast('Betting opened')}
function lock(){if(window.rouletteGame?.active)return window.rouletteGame.lock();if(state.status==='betting'){clearInterval(timerHandle);setStatus('locked')}else toast('Betting is not open')}
function spin(){if(window.rouletteGame?.active)return window.rouletteGame.spin();if(state.status==='betting')lock();if(state.status!=='locked')return toast('Lock betting before spinning');setStatus('spinning');startWheelSpin();const n=1+Math.floor(Math.random()*36);state.result=n;setTimeout(()=>{const resultKey=`local:${state.round}:${n}`;holdSettlementBalances(resultKey);settleWheel(n,resultKey);state.status='result';setStatus('result');payout(n);toast('Result: '+n)},3100)}
function payout(n){if(window.rouletteGame?.active)return;for(const t of state.teams){t.funds+=settleBets(t.bets,n);t.bets=[]}renderBets();renderActivity();renderTeams()}
function next(){if(window.rouletteGame?.active)return window.rouletteGame.next();if(state.status!=='result')return toast('Finish the current round first');state.round++;$('roundNo').textContent=state.round;$('displayRound').textContent=state.round;clearWheelResult();setStatus('waiting');timerSeconds=60;renderTimer();toast('Ready for admin to open betting')}
function adjust(i,amt){if(window.rouletteGame?.active)return window.rouletteGame.adjust(i,amt);state.teams[i].funds=Math.max(0,state.teams[i].funds+amt);renderBets();renderTeams()}
function placeBet(spec,label){if(window.rouletteGame?.active)return window.rouletteGame.placeBet(spec,label);if(state.status!=='betting')return toast('Bets are locked');const amount=state.chipValue;let bet;try{bet=validateBet({...spec,amount})}catch(e){return toast(e.message)}const t=team();if(t.funds<amount)return toast('Not enough team funds');const id=makeBetId(bet),existing=t.bets.find(b=>makeBetId(b)===id);if(existing)existing.amount+=amount;else t.bets.push(bet);t.funds-=amount;recordActivity(`added ${money(amount)} to `+(label||labelBet(bet)));renderBets();renderScore();renderBoard()}
function boundaryBet(type,a,b){let nums=[a,b].sort((x,y)=>x-y);placeBet({type,numbers:nums})}
function renderTimer(){$('timerValue').textContent=timerSeconds;$('timerValue').classList.toggle('locked',state.status!=='betting')}
const wheelMotion={wheelRotation:0,ballRotation:0,spinning:false,wheelAnimation:null,ballAnimation:null,spinStartedAt:0,wheelBase:0,ballBase:0,resultKey:null,settleTimer:null,settleAnimationFrame:null,landingAngle:0};
function positionWheelPointer(angle,visible){
  const pointer=$('wheelPointer'),wheel=$('wheel'),wrap=wheel.parentElement,wheelRect=wheel.getBoundingClientRect(),wrapRect=wrap.getBoundingClientRect();
  const radians=angle*Math.PI/180,radius=wheelRect.width/2+8;
  pointer.style.left=`${wheelRect.left-wrapRect.left+wheelRect.width/2+Math.sin(radians)*radius}px`;
  pointer.style.top=`${wheelRect.top-wrapRect.top+wheelRect.height/2-Math.cos(radians)*radius}px`;
  pointer.style.transform=`translate(-50%,-50%) rotate(${angle}deg)`;
  pointer.classList.toggle('isVisible',visible);
}
function wheelBackground(){
  const stops=WHEEL_ORDER.map((n,i)=>`${RED_NUMBERS.has(n)?'#a82e37':'#111619'} ${i*10}deg ${(i+1)*10}deg`).join(',');
  $('wheelRotor').style.background=`conic-gradient(${stops})`;
  const svg=$('wheelNumbers'),ns='http://www.w3.org/2000/svg';svg.replaceChildren();
  WHEEL_ORDER.forEach((number,index)=>{
    const angleDeg=-90+(index+.5)*10,angle=angleDeg*Math.PI/180,radius=44;
    const label=document.createElementNS(ns,'text');label.setAttribute('x',String(50+Math.cos(angle)*radius));label.setAttribute('y',String(50+Math.sin(angle)*radius));
    label.setAttribute('transform',`rotate(${angleDeg+90} ${label.getAttribute('x')} ${label.getAttribute('y')})`);
    label.setAttribute('class',`pocketNumber ${RED_NUMBERS.has(number)?'pocketRed':'pocketBlack'}`);label.textContent=String(number);svg.append(label);
  });
}
function startWheelSpin(){
  if(wheelMotion.spinning||wheelMotion.settleTimer)return;
  const rotor=$('wheelRotor'),ball=$('wheelBallTrack');wheelMotion.spinning=true;wheelMotion.resultKey=null;
  positionWheelPointer(0,false);
  $('resultBadge').classList.add('isPending');$('resultNum').textContent='—';$('displayNumber').textContent='—';$('displayLabel').textContent='';
  wheelMotion.wheelBase=wheelMotion.wheelRotation;wheelMotion.ballBase=wheelMotion.ballRotation;wheelMotion.spinStartedAt=performance.now();
  rotor.style.transform=`rotate(${wheelMotion.wheelBase}deg)`;ball.style.transform=`rotate(${wheelMotion.ballBase}deg)`;
  wheelMotion.wheelAnimation=rotor.animate([{transform:`rotate(${wheelMotion.wheelBase}deg)`},{transform:`rotate(${wheelMotion.wheelBase+360}deg)`}],{duration:900,iterations:Infinity,easing:'linear'});
  wheelMotion.ballAnimation=ball.animate([{transform:`rotate(${wheelMotion.ballBase}deg)`},{transform:`rotate(${wheelMotion.ballBase-360}deg)`}],{duration:680,iterations:Infinity,easing:'linear'});
}
function settleWheel(number,resultKey){
  if(wheelMotion.resultKey===resultKey)return;
  if(!wheelMotion.spinning)startWheelSpin();
  wheelMotion.resultKey=resultKey;const rotor=$('wheelRotor'),ball=$('wheelBallTrack'),badge=$('resultBadge');
  const color=colorOf(number);$('resultNum').textContent='—';$('displayNumber').textContent='—';$('displayLabel').textContent='';badge.classList.add('isPending');
  if(wheelMotion.settleTimer){clearTimeout(wheelMotion.settleTimer);wheelMotion.settleTimer=null}
  if(wheelMotion.spinning){
    const elapsed=performance.now()-wheelMotion.spinStartedAt;
    wheelMotion.wheelRotation=wheelMotion.wheelBase+elapsed/900*360;
    wheelMotion.ballRotation=wheelMotion.ballBase-elapsed/680*360;
    wheelMotion.wheelAnimation?.cancel();wheelMotion.ballAnimation?.cancel();
    wheelMotion.spinning=false;
  }
  const rotorStart=wheelMotion.wheelRotation,ballStart=wheelMotion.ballRotation;
  rotor.style.transitionDuration='0ms';ball.style.transitionDuration='0ms';
  rotor.style.transform=`rotate(${rotorStart}deg)`;ball.style.transform=`rotate(${ballStart}deg)`;
  void rotor.offsetWidth;

  // Choose a shared duration and paths that preserve the current speed while
  // giving the ball a more visible, gradual slowdown into its final position.
  // Spin uses millisecond animation durations (900 ms / 680 ms), while this
  // deceleration calculation uses seconds. Convert the ball's rate to deg/s.
  const wheelSpeed=400,ballSpeed=360/0.680;
  const pocketTarget=(WHEEL_ORDER.indexOf(number)+.5)*10+stablePocketOffset(resultKey);
  const phase=((ballStart-rotorStart-pocketTarget)%360+360)%360;
  // Keep the initial speed continuous, but ease the final pocket approach
  // over a longer, slower tail instead of extending the whole spin.
  const ballEaseStartSlope=3;
  const decelerationDistanceRate=wheelSpeed/2+ballSpeed/ballEaseStartSlope;
  const minDuration=7500,maxDuration=10500;
  const minLap=Math.max(0,Math.ceil((minDuration/1000*decelerationDistanceRate-phase)/360));
  const maxLap=Math.floor((maxDuration/1000*decelerationDistanceRate-phase)/360);
  const lapCount=minLap<=maxLap?minLap+Math.floor(Math.random()*(maxLap-minLap+1)):Math.max(1,Math.round((9000/1000*decelerationDistanceRate-phase)/360));
  const duration=(phase+360*lapCount)/decelerationDistanceRate;
  const wheelDelta=wheelSpeed*duration/2,ballDelta=ballSpeed*duration/ballEaseStartSlope;
  wheelMotion.landingAngle=((rotorStart+pocketTarget+wheelDelta)%360+360)%360;
  wheelMotion.wheelRotation=rotorStart+wheelDelta;
  wheelMotion.ballRotation=ballStart-ballDelta;

  let frameStart=performance.now(),finished=false;
  const finish=()=>{
    if(finished)return;finished=true;
    if(wheelMotion.settleAnimationFrame)cancelAnimationFrame(wheelMotion.settleAnimationFrame);
    wheelMotion.settleAnimationFrame=null;
    rotor.style.transform=`rotate(${wheelMotion.wheelRotation}deg)`;
    ball.style.transform=`rotate(${wheelMotion.ballRotation}deg)`;
    $('wheelInner').style.transform=`rotate(${-wheelMotion.wheelRotation}deg)`;
    if(wheelMotion.resultKey!==resultKey)return;
    badge.classList.toggle('isRed',color==='RED');badge.classList.toggle('isBlack',color==='BLACK');
    $('resultNum').textContent=String(number);badge.classList.remove('isPending');$('displayNumber').textContent=String(number);$('displayLabel').textContent=color;
    positionWheelPointer(wheelMotion.landingAngle,true);
    clearTimeout(wheelMotion.settleTimer);wheelMotion.settleTimer=null;releaseSettlementBalances(resultKey);renderActivity();
  };
  const animateStop=now=>{
    if(wheelMotion.resultKey!==resultKey)return;
    const progress=Math.min(1,(now-frameStart)/(duration*1000));
    const wheelEase=progress*(2-progress),ballEase=1-Math.pow(1-progress,ballEaseStartSlope);
    rotor.style.transform=`rotate(${rotorStart+wheelDelta*wheelEase}deg)`;
    ball.style.transform=`rotate(${ballStart-ballDelta*ballEase}deg)`;
    if(progress>=1)finish();else wheelMotion.settleAnimationFrame=requestAnimationFrame(animateStop);
  };
  wheelMotion.settleTimer=setTimeout(finish,duration*1000+250);
  wheelMotion.settleAnimationFrame=requestAnimationFrame(animateStop);
}
function clearWheelResult(){
  if(wheelMotion.settleTimer)return;
  if(heldBalanceKey)releaseSettlementBalances(heldBalanceKey);
  wheelMotion.resultKey=null;$('resultBadge').classList.add('isPending');$('resultBadge').classList.remove('isRed','isBlack');
  positionWheelPointer(0,false);
  $('resultNum').textContent='—';$('displayNumber').textContent='—';$('displayLabel').textContent='—';
}
function renderBoard(){
  const grid=$('tableGrid'),markerTargets=new Map(),teams=state.teams;
  const palette=['#5b8def','#e5a34b','#b36be0','#48b89a'];
  const colorFor=(teamId)=>{const index=teams.findIndex(t=>t.id===teamId);return palette[Math.max(0,index)%palette.length]};
  const allBets=teams.flatMap(t=>(t.bets||[]).map(b=>({...b,teamId:t.id,teamName:t.name})));
  const legend=$('teamBetLegend');
  legend.replaceChildren();
  teams.forEach((t,index)=>{const item=document.createElement('span'),dot=document.createElement('i');item.className='teamBetLegendItem';dot.className='teamBetDot';dot.style.background=palette[index%palette.length];item.append(dot,document.createTextNode(t.name));legend.append(item)});
  grid.replaceChildren();
  const key=(type,numbers)=>`${type}:${[...numbers].sort((a,b)=>a-b).join(',')}`;
  const addMarker=(host,bet)=>{
    let holder=host.querySelector('.boardBetMarkers');
    if(!holder){holder=document.createElement('span');holder.className='boardBetMarkers'+(host.classList.contains('boardCell')?' cellBetMarkers':'');host.append(holder)}
    const position=Math.min(holder.children.length,3);
    const marker=document.createElement('span');marker.className=`boardBetMarker teamMarker${position}`;marker.style.setProperty('--team-bet-color',colorFor(bet.teamId));
    marker.textContent=compactBetAmount(bet.amount);marker.title=`${bet.teamName}: $${Number(bet.amount).toLocaleString()}`;holder.append(marker);
  };
  for(let row=0;row<3;row++)for(let col=0;col<12;col++){
    const n=col*3+(row===0?3:row===1?2:1),wrap=document.createElement('div');
    wrap.className='boardCell';wrap.dataset.number=n;
    const button=document.createElement('button');button.className='num '+(RED_NUMBERS.has(n)?'red':'black');button.textContent=n;
    button.onclick=()=>placeBet({type:'straight',numbers:[n]},String(n));wrap.append(button);
    for(const straight of allBets.filter(b=>b.type==='straight'&&b.numbers[0]===n))addMarker(wrap,straight);
    const topNeighbor=row===0?null:n+1,bottomNeighbor=row===2?null:n-1,leftNeighbor=col===0?null:n-3,rightNeighbor=col===11?null:n+3;
    const target=(cls,aria,fn,betKey)=>{
      const targetButton=document.createElement('button');targetButton.type='button';targetButton.className='hitTarget '+cls;
      targetButton.setAttribute('aria-label',aria);targetButton.title=aria;
      targetButton.onclick=e=>{e.stopPropagation();fn()};wrap.append(targetButton);
      if(betKey){if(!markerTargets.has(betKey))markerTargets.set(betKey,targetButton);}
    };
    if(topNeighbor)target('edge topEdge',`Split ${n} and ${topNeighbor}`,()=>boundaryBet('split',n,topNeighbor),key('split',[n,topNeighbor]));
    if(bottomNeighbor)target('edge bottomEdge',`Split ${n} and ${bottomNeighbor}`,()=>boundaryBet('split',n,bottomNeighbor),key('split',[n,bottomNeighbor]));
    if(leftNeighbor)target('edge leftEdge',`Split ${n} and ${leftNeighbor}`,()=>boundaryBet('split',n,leftNeighbor),key('split',[n,leftNeighbor]));
    if(rightNeighbor)target('edge rightEdge',`Split ${n} and ${rightNeighbor}`,()=>boundaryBet('split',n,rightNeighbor),key('split',[n,rightNeighbor]));
    for(const [corner,dr,dc] of [['tl',-1,-1],['tr',-1,1],['bl',1,-1],['br',1,1]]){
      const rr=row+dr,cc=col+dc;if(rr<0||rr>=3||cc<0||cc>=12)continue;
      const rowNumber=(r,c)=>c*3+(r===0?3:r===1?2:1),other=rowNumber(rr,cc);
      const nums=[n,other,rowNumber(row,cc),rowNumber(rr,col)];if(new Set(nums).size!==4)continue;
      target('cornerTarget '+corner,`Corner ${nums.join(', ')}`,()=>placeBet({type:'corner',numbers:nums}),key('corner',nums));
    }
    if(row===1){const nums=[col*3+1,col*3+2,col*3+3];target('streetTarget',`Street ${nums.join(', ')}`,()=>placeBet({type:'street',numbers:nums}),key('street',nums));}
    if(row===1&&col<11){const nums=Array.from({length:6},(_,i)=>col*3+i+1);target('sixTarget',`Six-line ${nums[0]} through ${nums[5]}`,()=>placeBet({type:'six-line',numbers:nums}),key('six-line',nums));}
    grid.append(wrap);
  }
  for(const bet of allBets.filter(item=>['split','street','corner','six-line'].includes(item.type))){
    const markerTarget=markerTargets.get(key(bet.type,bet.numbers));if(!markerTarget)continue;
    markerTarget.classList.add('hasBetMarker');
    addMarker(markerTarget,bet);
  }
const outside=[['red','RED'],['black','BLACK'],['odd','ODD'],['even','EVEN'],['low','1–18'],['high','19–36'],['dozen','1st 12',1],['dozen','2nd 12',2],['dozen','3rd 12',3],['column','COL 1',1],['column','COL 2',2],['column','COL 3',3]];
const outsideGrid=$('outsideGrid');outsideGrid.replaceChildren();
outside.forEach(([type,label,value])=>{const button=document.createElement('button');button.type='button';button.className=`outside ${type==='red'?'red':''} ${type==='black'?'black':''}`;button.textContent=label;
  const matching=allBets.filter(b=>b.type===type&&(!value||b.value===value));
  if(matching.length){button.classList.add('hasBetMarks');const holder=document.createElement('span');holder.className='outsideBetMarks';for(const bet of matching){const mark=document.createElement('i');mark.style.background=colorFor(bet.teamId);mark.textContent=`$${Number(bet.amount).toLocaleString()}`;mark.title=`${bet.teamName}: $${Number(bet.amount).toLocaleString()}`;holder.append(mark)}button.append(holder)}
  button.onclick=()=>placeBet({type,value,numbers:numbersFor(type,value)},label);outsideGrid.append(button)});
renderTimer()}
function show(view){$('playerView').classList.toggle('hide',view!=='player');$('adminView').classList.toggle('show',view==='admin');$('displayView').classList.toggle('show',view==='display');document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));$(view==='player'?'playerTab':view==='admin'?'adminTab':'displayTab').classList.add('active')}

$('playerTab').onclick=()=>show('player');$('adminTab').onclick=()=>show('admin');$('displayTab').onclick=()=>show('display');$('spinBtn').onclick=spin;$('adminSpin').onclick=spin;$('lockBtn').onclick=lock;$('adminLock').onclick=lock;$('startBetting').onclick=startBetting;$('nextRound').onclick=next;
$('applySettings').onclick=()=>{state.round=+$('adminRound').value||1;const funds=+$('startFunds').value||0;team().funds=funds;$('roundNo').textContent=state.round;$('displayRound').textContent=state.round;renderBets();renderTeams();toast('Settings applied')};$('resetBtn').onclick=()=>location.reload();
let pointerResizeFrame=0;
const repositionVisibleWheelPointer=()=>{
  if(!$('wheelPointer').classList.contains('isVisible'))return;
  cancelAnimationFrame(pointerResizeFrame);
  pointerResizeFrame=requestAnimationFrame(()=>positionWheelPointer(wheelMotion.landingAngle,true));
};
window.addEventListener('resize',repositionVisibleWheelPointer,{passive:true});
window.addEventListener('orientationchange',repositionVisibleWheelPointer,{passive:true});
window.rouletteApp={state,team,renderBets,renderActivity,renderTeams,renderScore,renderBoard,setStatus,renderTimer,setTimer:(value)=>{timerSeconds=value;renderTimer()},visibleFunds,holdSettlementBalances,releaseSettlementBalances,startWheelSpin,settleWheel,clearWheelResult,toast,show};
renderChipTray();renderBets();renderActivity();renderTeams();renderBoard();wheelBackground();setStatus('waiting');
