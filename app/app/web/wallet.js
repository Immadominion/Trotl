// Throtl browser-wallet shim. Bridges the page's injected Solana wallets
// (Phantom / Solflare / Backpack / Glow / Coinbase / any standard provider) to the
// Flutter app as `window.throtlWallet`. Uses @solana/web3.js (window.solanaWeb3) to
// (de)serialize transactions, so Dart only passes base64 across the boundary.
//
// The app shows a PICKER: listWallets() enumerates every detected wallet, the user
// chooses one, and connect(id) connects to THAT wallet (not just whichever injected
// first). signTransactions SIGNS ONLY (the app submits) and serializes with
// requireAllSignatures:false so the arming tx's second in-memory signer (the Flash
// session key) can be injected by Dart afterward.
(function () {
  'use strict';

  // Discover every injected Solana provider on the page, de-duplicated.
  function detectWallets() {
    var list = [];
    function add(id, name, provider) {
      if (provider && !list.some(function (w) { return w.provider === provider; })) {
        list.push({ id: id, name: name, provider: provider });
      }
    }
    if (window.phantom && window.phantom.solana) add('phantom', 'Phantom', window.phantom.solana);
    if (window.solflare && window.solflare.isSolflare) add('solflare', 'Solflare', window.solflare);
    if (window.backpack) add('backpack', 'Backpack', window.backpack);
    if (window.glowSolana) add('glow', 'Glow', window.glowSolana);
    else if (window.glow) add('glow', 'Glow', window.glow);
    if (window.coinbaseSolana) add('coinbase', 'Coinbase Wallet', window.coinbaseSolana);
    if (window.trustwallet && window.trustwallet.solana) add('trust', 'Trust', window.trustwallet.solana);
    // a generic injected provider not already covered (some wallets only set window.solana)
    if (window.solana) {
      var nm = window.solana.isPhantom ? 'Phantom'
        : window.solana.isSolflare ? 'Solflare'
        : window.solana.isBackpack ? 'Backpack' : 'Injected Wallet';
      add('injected', nm, window.solana);
    }
    return list;
  }

  var _active = null; // the chosen wallet { id, name, provider }

  function activeProvider() {
    if (_active && _active.provider) return _active.provider;
    var first = detectWallets()[0];
    return first ? first.provider : null;
  }

  function b64ToBytes(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }
  function bytesToB64(buf) {
    var arr = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    var bin = '';
    for (var i = 0; i < arr.length; i++) bin += String.fromCharCode(arr[i]);
    return btoa(bin);
  }
  function web3() {
    if (!window.solanaWeb3) throw new Error('Solana web3.js not loaded');
    return window.solanaWeb3;
  }
  function pubkeyOf(resp, provider) {
    var pk = resp && resp.publicKey ? resp.publicKey : provider.publicKey;
    return pk ? pk.toString() : null;
  }

  window.throtlWallet = {
    available: function () { return detectWallets().length > 0; },

    // JSON array of { id, name } for the connect picker.
    listWallets: function () {
      return JSON.stringify(detectWallets().map(function (w) { return { id: w.id, name: w.name }; }));
    },

    walletName: function () { return _active ? _active.name : null; },

    // Connect to a specific wallet by id (falls back to the first if id is empty).
    connect: async function (id) {
      var wallets = detectWallets();
      var w = id ? wallets.filter(function (x) { return x.id === id; })[0] : wallets[0];
      if (!w) throw new Error('Wallet not found. Install Phantom, Solflare, or Backpack.');
      var resp = await w.provider.connect();
      var pk = pubkeyOf(resp, w.provider);
      if (!pk) throw new Error('Wallet did not return a public key');
      _active = w;
      return pk;
    },

    // Silent reconnect to any wallet that already trusts this origin (no popup).
    eagerConnect: async function () {
      var wallets = detectWallets();
      for (var i = 0; i < wallets.length; i++) {
        try {
          var resp = await wallets[i].provider.connect({ onlyIfTrusted: true });
          var pk = pubkeyOf(resp, wallets[i].provider);
          if (pk) { _active = wallets[i]; return pk; }
        } catch (e) { /* not trusted — try the next */ }
      }
      return null;
    },

    signTransactions: async function (b64Txs) {
      var p = activeProvider();
      if (!p) throw new Error('No wallet connected');
      var w3 = web3();
      var txs = b64Txs.map(function (b64) { return w3.Transaction.from(b64ToBytes(b64)); });
      var signed = p.signAllTransactions
        ? await p.signAllTransactions(txs)
        : await Promise.all(txs.map(function (t) { return p.signTransaction(t); }));
      return signed.map(function (t) {
        return bytesToB64(t.serialize({ requireAllSignatures: false, verifySignatures: false }));
      });
    },

    signAndSend: async function (b64Txs) {
      var p = activeProvider();
      if (!p) throw new Error('No wallet connected');
      var w3 = web3();
      var sigs = [];
      for (var i = 0; i < b64Txs.length; i++) {
        var tx = w3.Transaction.from(b64ToBytes(b64Txs[i]));
        var res = await p.signAndSendTransaction(tx);
        sigs.push(res && res.signature ? res.signature : res);
      }
      return sigs;
    },

    disconnect: async function () {
      var p = _active && _active.provider;
      if (p && p.disconnect) { try { await p.disconnect(); } catch (e) { /* best-effort */ } }
      _active = null;
    },
  };
})();
