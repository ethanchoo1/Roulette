(function () {
  const $ = (id) => document.getElementById(id);
  const app = window.rouletteApp;
  const chip = (value) => `$${Number(value).toLocaleString()}`;
  const betNames = {
    straight: 'number', split: 'split', street: 'street', corner: 'corner',
    'six-line': 'six-line', dozen: 'dozen', column: 'column',
    red: 'red', black: 'black', odd: 'odd', even: 'even', low: '1–18', high: '19–36'
  };
  function activityText(item) {
    const team = item.team_name ? ` (${item.team_name} team)` : '';
    const amount = Math.abs(Number(item.amount_delta || 0));
    const numbers = (item.numbers || []).join(', ');
    let bet = betNames[item.bet_type] || item.bet_type || 'bet';
    if (item.bet_type === 'straight') bet += ` ${numbers}`;
    else if (['split', 'street', 'corner', 'six-line'].includes(item.bet_type)) bet += ` ${numbers}`;
    else if (item.bet_type === 'dozen') {
      const ordinal = ['1st', '2nd', '3rd'][Math.floor(((item.numbers?.[0] || 1) - 1) / 12)];
      bet = `${ordinal} dozen`;
    } else if (item.bet_type === 'column') {
      bet += ` ${((item.numbers?.[0] || 1) - 1) % 3 + 1}`;
    }

    if (item.action === 'joined') return `joined ${item.team_name} team`;
    if (item.action === 'wager') return `placed ${chip(amount)} on ${bet}${team}`;
    if (item.action === 'bet_refund') return `removed ${chip(amount)} from ${bet}${team}`;
    if (item.action === 'payout') return `won ${chip(amount)} in round ${item.round_number}${team}`;
    if (item.action === 'admin_adjustment') {
      const signed = Number(item.amount_delta) > 0 ? `+${chip(amount)}` : `−${chip(amount)}`;
      return `${item.team_name} bankroll adjusted ${signed}${item.reason ? ` · ${item.reason}` : ''}`;
    }
    return `${item.action}${team}`;
  }
  const backend = {
    active: false,
    ready: false,
    client: null,
    context: null,
    snapshot: null,
    channel: null,
    pollHandle: null,
    timerHandle: null,
    busy: false,
    refreshing: false,

    async enter() {
      if (this.busy) return;
      this.busy = true;
      $('enterTableBtn').disabled = true;
      $('connectMessage').textContent = 'Loading the shared table…';
      try {
        this.client = window.rouletteSupabaseClient;
        this.context = window.ROULETTE_MEMBERSHIP_CONTEXT || {};
        // Membership is also persisted so a restored page can recover if the
        // connection view was created before its in-memory context was filled.
        if (!this.context.eventId) {
          try {
            const saved = JSON.parse(localStorage.getItem('roulette-night-membership') || 'null');
            if (saved?.eventId) this.context.eventId = saved.eventId;
          } catch { /* Ignore malformed local membership data. */ }
        }
        if (!this.client) throw new Error('Supabase is not initialized yet. Reload the page and try again.');
        if (!this.context.eventId) throw new Error('This browser has no saved event membership. Enter the invite code and sign in again.');
        window.ROULETTE_MEMBERSHIP_CONTEXT = this.context;
        this.active = true;
        await this.refresh();
        this.configureRole();
        $('connectGate').hidden = true;
        app.show(this.context.role === 'admin' ? 'admin' : 'player');
        this.subscribe();
        // Polling also carries short spinning-state transitions for guests
        // whose project has not enabled Supabase Realtime on these tables.
        this.pollHandle = setInterval(() => this.refreshQuietly(), 1000);
        this.timerHandle = setInterval(() => this.updateClock(), 1000);
        this.updateClock();
      } catch (error) {
        this.active = false;
        $('connectMessage').textContent = error.message || 'Could not load the shared game state.';
      } finally {
        this.busy = false;
        $('enterTableBtn').disabled = false;
      }
    },

    configureRole() {
      const admin = this.context.role === 'admin';
      $('adminTab').hidden = !admin;
      $('playerTab').hidden = admin;
      $('spinBtn').hidden = true;
      $('lockBtn').hidden = true;
      $('applySettings').hidden = true;
      $('resetBtn').hidden = true;
      $('roundControl').hidden = !admin;
    },

    async refresh() {
      if (this.refreshing) return this.snapshot;
      this.refreshing = true;
      try {
      const { data, error } = await this.client.rpc('get_game_snapshot', {
        p_event_id: this.context.eventId
      });
      if (error) throw error;
      this.snapshot = data;
      this.render(data);
      return data;
      } finally { this.refreshing = false; }
    },

    async refreshQuietly() {
      if (!this.active || this.busy) return;
      try { await this.refresh(); }
      catch (error) {
        if (String(error.message || '').includes('NOT_EVENT_MEMBER')) {
          this.active = false;
          clearInterval(this.pollHandle);
          clearInterval(this.timerHandle);
          if (this.channel) this.client.removeChannel(this.channel);
          const cache = JSON.parse(localStorage.getItem('roulette-night-membership') || 'null');
          localStorage.removeItem('roulette-night-membership');
          $('connectGate').hidden = false;
          $('connectedView').hidden = true;
          $('teamChoiceView').hidden = true;
          $('connectFormView').hidden = false;
          $('joinCodeInput').value = cache?.joinCode || localStorage.getItem('roulette-night-last-join-code') || '';
          $('displayNameInput').value = cache?.displayName || '';
          $('connectMessage').textContent = 'Your membership was removed. You can rejoin with the same guest identity and invite code.';
        } else {
          app.toast(error.message || 'Could not refresh the table.');
        }
      }
    },

    render(snapshot) {
      const round = snapshot.round || {};
      const settlementKey = round.winning_number != null ? `${round.id}:${round.winning_number}` : null;
      if (settlementKey) app.holdSettlementBalances(settlementKey);
      const teams = (snapshot.teams || []).map((row) => ({
        id: row.id,
        name: row.name,
        funds: Number(row.balance),
        players: null,
        bets: (snapshot.bets || []).filter((bet) => bet.team_id === row.id).map((bet) => ({
          type: bet.bet_type,
          numbers: bet.numbers,
          amount: Number(bet.amount),
          value: bet.bet_type === 'dozen' ? Math.floor((bet.numbers[0] - 1) / 12) + 1
            : bet.bet_type === 'column' ? ((bet.numbers[0] - 1) % 3) + 1 : undefined
        }))
      }));
      const teamIndex = teams.findIndex((row) => row.id === snapshot.team_id);
      Object.assign(app.state, {
        event: snapshot.event,
        round: round.display_round_number || round.round_number || 0,
        status: round.status || 'waiting',
        result: round.winning_number ?? null,
        bettingDeadline: round.betting_deadline || null,
        chipValue: app.state.chipValue || 25,
        activeTeam: Math.max(0, teamIndex),
        teams
      });

      $('roundNo').textContent = round.display_round_number || round.round_number || '—';
      $('displayRound').textContent = round.display_round_number || round.round_number || '—';
      document.querySelector('.betHint').textContent = `Selected chip: ${chip(app.state.chipValue)}. Choose a number or bet area.`;
      $('teamPanelName').textContent = teamIndex >= 0 ? `${teams[teamIndex].name} TEAM` : 'Event teams';
      $('playerCountLabel').textContent = 'shared team bankroll';
      if (['betting', 'locked', 'spinning'].includes(round.status)) {
        app.startWheelSpin();
      } else if (round.winning_number != null) {
        app.settleWheel(round.winning_number, `${round.id}:${round.winning_number}`);
      } else {
        app.clearWheelResult();
      }

      app.state.activity = (snapshot.activity || []).map((item) => ({
        actor: item.actor,
        detail: activityText(item),
        action: item.action,
        roundNumber: item.round_number
      }));

      app.setStatus(app.state.status);
      this.updateClock();
      app.renderBets();
      app.renderActivity();
      app.renderTeams();
      app.renderScore();
      app.renderBoard();
    },

    renderTeams() {
      const root = $('teamManage');
      root.replaceChildren();
      if (this.context.role !== 'admin') return;
      for (const team of app.state.teams) {
        const row = document.createElement('div');
        const name = document.createElement('span');
        const funds = document.createElement('strong');
        const add = document.createElement('button');
        const subtract = document.createElement('button');
        const setBalance = document.createElement('button');
        const remove = document.createElement('button');
        const identity = document.createElement('div');
        const actions = document.createElement('div');
        row.className = 'liveManageRow';
        identity.className = 'adminTeamIdentity';
        actions.className = 'adminTeamActions';
        name.textContent = team.name;
        name.className = 'adminTeamName';
        funds.textContent = chip(app.visibleFunds(team));
        funds.className = 'adminTeamFunds';
        add.type = subtract.type = 'button';
        add.className = subtract.className = 'btn';
        setBalance.type = remove.type = 'button';
        setBalance.className = 'btn';
        remove.className = 'btn danger teamDeleteBtn';
        add.textContent = '+$100';
        subtract.textContent = '−$100';
        setBalance.textContent = 'SET BALANCE';
        remove.textContent = 'DELETE';
        add.addEventListener('click', () => this.adjust(team.id, 100));
        subtract.addEventListener('click', () => this.adjust(team.id, -100));
        setBalance.addEventListener('click', () => this.setBalance(team));
        remove.addEventListener('click', () => this.deleteTeam(team));
        identity.append(name, funds);
        actions.append(add, subtract, setBalance, remove);
        row.append(identity, actions);
        root.append(row);

        const members = (this.snapshot?.members || []).filter((member) => member.team_id === team.id);
        const roster = document.createElement('div');
        roster.className = 'memberRoster';
        const heading = document.createElement('div');
        heading.className = 'rosterHeading';
        heading.textContent = `Players (${members.length})`;
        roster.append(heading);
        if (!members.length) {
          const empty = document.createElement('div');
          empty.className = 'rosterEmpty';
          empty.textContent = 'No players on this team yet.';
          roster.append(empty);
        }
        for (const member of members) {
          const memberRow = document.createElement('div');
          const displayName = document.createElement('span');
          const kick = document.createElement('button');
          memberRow.className = 'rosterMember';
          displayName.textContent = member.display_name;
          kick.type = 'button';
          kick.className = 'btn kickMemberBtn';
          kick.textContent = 'REMOVE';
          kick.setAttribute('aria-label', `Remove ${member.display_name} from the event`);
          kick.addEventListener('click', () => this.kickMember(member));
          memberRow.append(displayName, kick);
          roster.append(memberRow);
        }
        root.append(roster);
      }
    },

    kickMember(member) {
      const confirmed = window.confirm(
        `Remove ${member.display_name} from this event? They can rejoin with the same browser identity. The team bankroll and bets will remain unchanged.`
      );
      if (!confirmed) return;
      return this.action(() => this.callAdmin('admin_kick_member', {
        p_event_id: this.context.eventId,
        p_user_id: member.user_id
      }), `${member.display_name} was removed. They can rejoin with the same browser identity.`);
    },

    setBalance(team) {
      const raw = window.prompt(`Set ${team.name} team balance to an exact whole dollar amount:`, String(team.funds));
      if (raw === null) return;
      const amount = raw.trim();
      if (!/^\d+$/.test(amount) || !Number.isSafeInteger(Number(amount))) {
        return app.toast('Enter a nonnegative whole dollar amount.');
      }
      return this.action(async () => {
        const { error } = await this.client.rpc('admin_set_team_balance', {
          p_event_id: this.context.eventId,
          p_team_id: team.id,
          p_balance: Number(amount),
          p_reason: 'Manual balance set',
          p_request_id: crypto.randomUUID()
        });
        if (error) throw error;
        await this.refresh();
      }, `${team.name} balance set to ${chip(amount)}.`);
    },

    deleteTeam(team) {
      const confirmed = window.confirm(
        `Delete ${team.name}? This permanently deletes its event memberships, bets, bankroll ledger, and related activity history. Players keep their guest accounts and can rejoin another team. This is only allowed while no round is active.`
      );
      if (!confirmed) return;
      return this.action(() => this.callAdmin('admin_delete_team', {
        p_event_id: this.context.eventId,
        p_team_id: team.id
      }), `${team.name} was deleted.`);
    },

    subscribe() {
      const eventId = this.context.eventId;
      this.channel = this.client.channel(`roulette-event-${eventId}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'rounds', filter: `event_id=eq.${eventId}` }, () => this.refreshQuietly())
        .on('postgres_changes', { event: '*', schema: 'public', table: 'teams', filter: `event_id=eq.${eventId}` }, () => this.refreshQuietly())
        .on('postgres_changes', { event: '*', schema: 'public', table: 'bets', filter: `event_id=eq.${eventId}` }, () => this.refreshQuietly())
        .subscribe();
    },

    async callAdmin(name, args) {
      if (this.context.role !== 'admin') return app.toast('Admin access is required.');
      const { error } = await this.client.rpc(name, args);
      if (error) throw error;
      await this.refresh();
    },

    async action(work, successMessage) {
      if (this.busy) return;
      this.busy = true;
      try {
        await work();
        if (successMessage) app.toast(successMessage);
      } catch (error) {
        app.toast(error.message || 'The request failed.');
        await this.refreshQuietly();
      } finally { this.busy = false; }
    },

    startBetting() {
      return this.action(async () => {
        let round = this.snapshot?.round;
        if (!round || round.status === 'result') {
          await this.callAdmin('admin_prepare_round', { p_event_id: this.context.eventId });
        }
        await this.callAdmin('admin_start_betting', { p_event_id: this.context.eventId });
      }, 'Betting is open.');
    },

    lock() {
      return this.action(() => this.callAdmin('admin_lock_bets', { p_event_id: this.context.eventId }), 'Bets locked.');
    },

    spin() {
      return this.action(() => this.callAdmin('admin_spin_round', { p_event_id: this.context.eventId }), 'Wheel spinning.');
    },

    next() {
      if (app.state.status !== 'result') return app.toast('Finish the current round first.');
      return this.action(() => this.callAdmin('admin_prepare_round', { p_event_id: this.context.eventId }), 'Next round is ready.');
    },

    resetRoundCounter() {
      const confirmed = window.confirm(
        'Start the displayed counter over at Round 1? The current waiting round will become Round 1, or a new one will be created after a result. Previous results and history will remain.'
      );
      if (!confirmed) return;
      return this.action(() => this.callAdmin('admin_reset_round_counter', {
        p_event_id: this.context.eventId
      }), 'The next game is ready as Round 1.');
    },

    placeBet(spec) {
      if (app.state.status !== 'betting') return app.toast('Bets are locked.');
      const currentTeam = app.team();
      if (!currentTeam) return app.toast('Join a team before betting.');
      const chipValue = app.state.chipValue;
      let bet;
      try { bet = Roulette.validateBet({ ...spec, amount: chipValue }); }
      catch (error) { return app.toast(error.message); }
      if (currentTeam.funds < chipValue) return app.toast('Not enough team funds.');
      return this.action(async () => {
        const { error } = await this.client.rpc('member_change_bet', {
          p_event_id: this.context.eventId,
          p_bet_type: bet.type,
          p_numbers: bet.numbers,
          p_delta: chipValue,
          p_request_id: crypto.randomUUID()
        });
        if (error) throw error;
        await this.refresh();
      });
    },

    changeBet(id, delta) {
      if (app.state.status !== 'betting') return app.toast('Bets are locked.');
      const bet = app.team()?.bets.find((item) => Roulette.makeBetId(item) === id);
      if (!bet) return;
      if (delta > 0 && app.team().funds < delta) return app.toast('Not enough team funds.');
      const amount = delta > 0 ? app.state.chipValue : Math.min(app.state.chipValue, bet.amount);
      if (delta < 0 && amount <= 0) return app.toast('That bet is already at its minimum.');
      return this.action(async () => {
        const { error } = await this.client.rpc('member_change_bet', {
          p_event_id: this.context.eventId,
          p_bet_type: bet.type,
          p_numbers: bet.numbers,
          p_delta: delta > 0 ? amount : -amount,
          p_request_id: crypto.randomUUID()
        });
        if (error) throw error;
        await this.refresh();
      });
    },

    adjust(teamId, delta) {
      return this.action(async () => {
        const { error } = await this.client.rpc('admin_adjust_team_balance', {
          p_event_id: this.context.eventId,
          p_team_id: teamId,
          p_delta: delta,
          p_reason: 'Admin bankroll adjustment',
          p_request_id: crypto.randomUUID()
        });
        if (error) throw error;
        await this.refresh();
      });
    },

    updateClock() {
      const deadline = app.state.bettingDeadline;
      if (app.state.status !== 'betting' || !deadline) return app.setTimer(0);
      app.setTimer(Math.max(0, Math.ceil((Date.parse(deadline) - Date.now()) / 1000)));
    }
  };

  window.rouletteGame = backend;
  $('enterTableBtn').addEventListener('click', () => backend.enter());
  $('resetRoundCounter').addEventListener('click', () => backend.resetRoundCounter());
})();
