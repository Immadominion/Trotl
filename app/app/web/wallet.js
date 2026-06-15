// Throtl browser-wallet shim. Bridges the page's injected Solana wallet
// (Phantom / Solflare / Backpack) to the Flutter app as `window.throtlWallet`.
// Uses @solana/web3.js (loaded as `window.solanaWeb3` in index.html) to (de)serialize
// transactions, so Dart only ever passes base64 across the boundary.
//
// Contract mirrors the mobile MWA backend: `signTransactions` SIGNS ONLY (the app
// submits), and serializes with requireAllSignatures:false so the arming tx's
// second, in-memory signer (the Flash session key) can be injected by Dart afterward.
(function () {
  'use strict';

  function getProvider() {
    if (window.phantom && window.phantom.solana && window.phantom.solana.isPhantom) {
      return window.phantom.solana;
    }
    if (window.solflare && window.solflare.isSolflare) return window.solflare;
    if (window.backpack) return window.backpack;
    if (window.solana) return window.solana; // generic injected provider
    return null;
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

  function requireProvider() {
    var p = getProvider();
    if (!p) throw new Error('No Solana wallet found. Install Phantom, Solflare, or Backpack.');
    return p;
  }

  window.throtlWallet = {
    available: function () {
      return !!getProvider();
    },

    walletName: function () {
      var p = getProvider();
      if (!p) return null;
      if (p.isPhantom) return 'Phantom';
      if (p.isSolflare) return 'Solflare';
      if (p.isBackpack) return 'Backpack';
      return 'Wallet';
    },

    connect: async function () {
      var p = requireProvider();
      var resp = await p.connect();
      var pk = resp && resp.publicKey ? resp.publicKey : p.publicKey;
      return pk.toString();
    },

    // Silent reconnect — only if the wallet already trusts this origin (no popup).
    eagerConnect: async function () {
      var p = getProvider();
      if (!p) return null;
      try {
        var resp = await p.connect({ onlyIfTrusted: true });
        var pk = resp && resp.publicKey ? resp.publicKey : p.publicKey;
        return pk ? pk.toString() : null;
      } catch (e) {
        return null;
      }
    },

    signTransactions: async function (b64Txs) {
      var p = requireProvider();
      var w3 = web3();
      var txs = b64Txs.map(function (b64) {
        return w3.Transaction.from(b64ToBytes(b64));
      });
      var signed;
      if (p.signAllTransactions) {
        signed = await p.signAllTransactions(txs);
      } else {
        signed = [];
        for (var i = 0; i < txs.length; i++) signed.push(await p.signTransaction(txs[i]));
      }
      return signed.map(function (t) {
        return bytesToB64(t.serialize({ requireAllSignatures: false, verifySignatures: false }));
      });
    },

    signAndSend: async function (b64Txs) {
      var p = requireProvider();
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
      var p = getProvider();
      if (p && p.disconnect) {
        try {
          await p.disconnect();
        } catch (e) {
          /* best-effort */
        }
      }
    },
  };
})();
