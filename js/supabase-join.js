(function () {
  const $ = (id) => document.getElementById(id);
  const config = window.ROULETTE_SUPABASE_CONFIG;
  const storageKey = 'roulette-night-membership';
  const queryCode = new URLSearchParams(location.search).get('join') || '';
  let client = null;
  let currentOptions = null;
  let currentDisplayName = '';

  function message(text) {
    $('connectMessage').textContent = text || '';
  }

  function busy(form, isBusy) {
    form.querySelectorAll('button').forEach((button) => {
      button.disabled = isBusy;
      button.classList.toggle('busy', isBusy);
    });
  }

  function showView(view) {
    $('connectFormView').hidden = view !== 'form';
    $('teamChoiceView').hidden = view !== 'teams';
    $('connectedView').hidden = view !== 'connected';
    message('');
  }

  function savedMembership() {
    try { return JSON.parse(localStorage.getItem(storageKey) || 'null'); }
    catch { return null; }
  }

  function saveMembership(eventId, joinCode, displayName) {
    localStorage.setItem(storageKey, JSON.stringify({ eventId, joinCode, displayName }));
  }

  function showConnected({ eventId, eventName, role, team, displayName }) {
    $('connectedTitle').textContent = role === 'admin' ? 'Admin access is ready' : `Welcome, ${displayName || 'player'}`;
    $('connectedDetail').textContent = role === 'admin'
      ? `You’re signed in as an administrator for ${eventName}.`
      : `You’re on ${team?.name || 'your team'} in ${eventName}. Available team funds: $${Number(team?.balance || 0).toLocaleString()}.`;
    $('connectNote').textContent = 'Your identity and membership are saved. The table will load live teams, bets, and round state from Supabase.';
    $('enterTableBtn').hidden = role !== 'admin' && !team;
    window.ROULETTE_MEMBERSHIP_CONTEXT = {
      eventId: eventId || null,
      eventName,
      role,
      teamId: team?.id || null,
      displayName: displayName || ''
    };
    showView('connected');
  }

  async function refreshMembership(eventId, cache) {
    const { data, error } = await client.rpc('get_game_snapshot', { p_event_id: eventId });
    if (error) throw error;
    const snapshot = data;
    const { data: userData, error: userError } = await client.auth.getUser();
    if (userError) throw userError;
    const { data: membership, error: membershipError } = await client
      .from('event_members')
      .select('role, display_name, team_id')
      .eq('event_id', eventId)
      .eq('user_id', userData.user.id)
      .maybeSingle();
    if (membershipError) throw membershipError;
    if (!membership) throw new Error('NOT_EVENT_MEMBER');
    const team = snapshot.teams?.find((item) => item.id === snapshot.team_id) || null;
    showConnected({
      eventId,
      eventName: snapshot.event?.name || 'Roulette Night',
      role: membership.role,
      team,
      displayName: membership.display_name || cache?.displayName
    });
    if (cache?.joinCode) $('joinCodeInput').value = cache.joinCode;
    return snapshot;
  }

  async function getJoinOptions(code) {
    const { data, error } = await client.rpc('get_join_options', { p_join_code: code });
    if (error) throw error;
    currentOptions = data;
    localStorage.setItem('roulette-night-last-join-code', code);

    // A returning player or provisioned admin already has a membership. Restore
    // it directly instead of asking them to choose a team again.
    const existing = await client.rpc('get_game_snapshot', { p_event_id: data.event_id });
    if (!existing.error) {
      const cache = savedMembership();
      saveMembership(data.event_id, code, cache?.displayName || currentDisplayName);
      await refreshMembership(data.event_id, { ...cache, joinCode: code });
      return;
    }
    if (!String(existing.error.message || '').includes('NOT_EVENT_MEMBER')) {
      throw existing.error;
    }

    const select = $('teamChoice');
    select.replaceChildren(new Option('Choose a team…', ''));
    for (const team of data.teams || []) {
      const option = new Option(`${team.name} (${team.players} ${team.players === 1 ? 'player' : 'players'})`, team.id);
      select.add(option);
    }
    $('joinEventName').textContent = data.event_name;
    $('newTeamNameInput').value = '';
    showView('teams');
  }

  async function ensureGuestSession() {
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError) throw sessionError;
    if (sessionData.session) return;
    const { error } = await client.auth.signInAnonymously();
    if (error) throw error;
  }

  function inviteCodeFromForm() {
    return $('joinCodeInput').value.trim();
  }

  $('guestStartForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const code = inviteCodeFromForm();
    currentDisplayName = $('displayNameInput').value.trim();
    if (!code || !currentDisplayName) return message('Enter the invite code and your name to continue.');
    busy(form, true);
    message('Connecting your guest session…');
    try {
      await ensureGuestSession();
      await getJoinOptions(code);
    } catch (error) {
      showView('form');
      message(error.message || 'Could not open this event. Check the invite code and try again.');
    } finally { busy(form, false); }
  });

  $('adminSignInForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const code = inviteCodeFromForm();
    if (!code) return message('Enter the event invite code first.');
    busy(form, true);
    message('Signing in…');
    try {
      const { error } = await client.auth.signInWithPassword({
        email: $('adminEmailInput').value.trim(),
        password: $('adminPasswordInput').value
      });
      if (error) throw error;
      await getJoinOptions(code);
    } catch (error) {
      showView('form');
      message(error.message || 'Admin sign-in failed.');
    } finally { busy(form, false); }
  });

  $('teamChoiceForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const selectedTeam = $('teamChoice').value;
    const newTeamName = $('newTeamNameInput').value.trim();
    if ((!selectedTeam && !newTeamName) || (selectedTeam && newTeamName)) {
      return message('Choose one existing team or enter a new team name.');
    }
    busy(form, true);
    message('Joining the team…');
    try {
      const code = inviteCodeFromForm();
      const { data, error } = await client.rpc('join_event', {
        p_join_code: code,
        p_display_name: currentDisplayName,
        p_team_id: selectedTeam || null,
        p_new_team_name: newTeamName || null
      });
      if (error) throw error;
      saveMembership(data.event_id, code, data.display_name);
      showConnected({
        eventId: data.event_id,
        eventName: currentOptions.event_name,
        role: data.role,
        team: data.team,
        displayName: data.display_name
      });
    } catch (error) {
      message(error.message || 'Could not join that team. Please try again.');
    } finally { busy(form, false); }
  });

  async function initialize() {
    if (!window.supabase?.createClient) {
      return message('Supabase client could not load. Check your internet connection and reload.');
    }
    if (!config?.url || !config?.publishableKey || config.url.includes('YOUR_') || config.publishableKey.includes('YOUR_')) {
      return message('Add your Supabase Project URL and publishable key to js/supabase-config.js, then reload.');
    }
    client = window.supabase.createClient(config.url, config.publishableKey, {
      auth: { persistSession: true, autoRefreshToken: true }
    });
    window.rouletteSupabaseClient = client;
    if (queryCode) $('joinCodeInput').value = queryCode;

    const { data: sessionData, error } = await client.auth.getSession();
    if (error) return message(error.message);
    const cache = savedMembership();
    if (sessionData.session && cache?.eventId) {
      $('joinCodeInput').value = queryCode || cache.joinCode || '';
      try {
        await refreshMembership(cache.eventId, cache);
        return;
      } catch (snapshotError) {
        // A kick removes only membership. Keep the Auth session so the player
        // can rejoin as the same identity using the same invite code.
        if (String(snapshotError.message || '').includes('NOT_EVENT_MEMBER')) {
          localStorage.removeItem(storageKey);
          $('joinCodeInput').value = queryCode || cache.joinCode || localStorage.getItem('roulette-night-last-join-code') || '';
          message('Your event membership is no longer active. Use the invite code to rejoin.');
        } else {
          message(snapshotError.message || 'Could not restore your event session.');
        }
        return;
      }
    }
    const rememberedCode = localStorage.getItem('roulette-night-last-join-code');
    $('joinCodeInput').value = queryCode || cache?.joinCode || rememberedCode || '';
  }

  initialize().catch((error) => message(error.message || 'Could not initialize Supabase.'));
})();
