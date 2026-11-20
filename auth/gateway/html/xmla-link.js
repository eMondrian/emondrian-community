// Power BI live connection: the server address with the user's personal token in it, for Power BI
// Desktop's live connection, which sends no saved password (auth/README.md, "Personal tokens").
//
// Served by the auth gateway and added by it to the entry page (emondrian-locations.conf,
// location = /), for entry images older than 1.5.0, which have no section of their own. Shows nothing when the tokens API refuses: authentication off (open access),
// tokens turned off, or not logged in. One token per user: issuing one here revokes the user's
// previous token, wherever it is used, so the page says so before it does.
;(function () {
  'use strict'
  var api = '/account/api/tokens'

  function el(tag, attrs, text) {
    var node = document.createElement(tag)
    for (var key in attrs || {}) node.setAttribute(key, attrs[key])
    if (text) node.textContent = text
    return node
  }
  function when(iso) {
    return iso ? iso.slice(0, 16).replace('T', ' ') + ' UTC' : ''
  }
  function call(method, body) {
    return fetch(api, {
      method: method,
      credentials: 'same-origin',
      headers: body ? { Accept: 'application/json', 'Content-Type': 'application/json' } : { Accept: 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    }).then(function (res) {
      return res.json().catch(function () { return {} }).then(function (data) {
        if (!res.ok) {
          var e = data.error
          throw new Error((e && (e.message || e)) || 'HTTP ' + res.status)
        }
        return data
      })
    })
  }

  // Where it goes: the entry page gets a section after "Connect a client". Entry 1.5.0 and later
  // have a Power BI section of their own on these tokens (data-personal-token): then nothing is
  // added. Entry 1.4.0 built its section (data-xmla-link) for the XML/A links (eml_) that were
  // removed, on /account/api/link, which now answers 410: that section is replaced by this one. The
  // entry's script keeps its references to the old elements, so whatever it does to them later
  // happens off the page.
  function mount() {
    if (document.querySelector('[data-personal-token]')) return null
    var section = el('section', { class: 'section', id: 'xmla-link-section', 'aria-labelledby': 'xmla-link-title' })
    section.append(el('h2', { class: 'section__title', id: 'xmla-link-title' }, 'Power BI live connection'))
    var card = el('div', { class: 'card connect' })
    section.append(card)
    var old = document.querySelector('[data-xmla-link]')
    if (old) {
      old.replaceWith(section)
      return card
    }
    var title = document.getElementById('connect-title')
    var after = title && title.closest('section')
    if (!after) return null
    after.after(section)
    return card
  }

  function render(box, state, fresh) {
    box.replaceChildren()
    box.append(el('p', {}, 'Power BI Desktop does not send a saved password on a live connection. ' +
      'Use the server address with your personal token in it instead; it signs you in by itself. ' +
      'Treat it like a password: anyone who has it queries the server as you.'))
    var current = state.tokens && state.tokens[0]

    if (fresh) {
      var url = location.origin + '/xmla?emondrian_token=' + fresh.token
      var row = el('div', { class: 'connect__row' })
      var code = el('code', { class: 'connect__url token', id: 'xmla-link-url' }, url)
      var copy = el('button', { type: 'button', class: 'button' }, 'Copy')
      copy.onclick = function () {
        navigator.clipboard.writeText(url).then(function () { copy.textContent = 'Copied' },
          function () { copy.textContent = 'Select it and copy' })
      }
      row.append(code, copy)
      box.append(row)
      box.append(el('p', { class: 'hint muted' }, 'Copy it now: it is not shown again. Valid until ' +
        when(fresh.expires) + '.' + (fresh.replaced && fresh.replaced.length ? ' Your previous token no longer works.' : '')))
    } else if (current) {
      box.append(el('p', { class: 'hint muted' }, 'You have a token (' + current.hint + '), valid until ' +
        when(current.expires) + (current.last_used ? ', last used ' + when(current.last_used) : ', not used yet') +
        '. Its value is not shown again; a new one replaces it.'))
    }

    var actions = el('div', { class: 'connect__row' })
    var get = el('button', { type: 'button', class: 'button' }, current || fresh ? 'Issue a new token' : 'Issue a token')
    get.onclick = function () {
      if ((current || fresh) && !confirm('A new token revokes your current one. Excel, Power BI, scripts and links ' +
          'that use it stop working until you give them the new one. Continue?')) return
      call('POST', { name: 'Power BI live connection' }).then(function (made) {
        load(box, made)
      }, function (e) { error(box, e) })
    }
    actions.append(get)
    actions.append(el('a', { href: '/account/tokens', class: 'button link' }, 'Manage tokens'))
    box.append(actions)
    box.append(el('p', { class: 'hint muted' }, 'Excel and Power BI import mode can use your user name and ' +
      'password, or the token as the password, instead.'))
  }

  function error(box, e) {
    box.append(el('p', { class: 'error' }, e.message))
  }

  function load(box, fresh) {
    call('GET').then(function (state) {
      render(box, state, fresh)
    }, function () {
      var section = document.getElementById('xmla-link-section')
      if (section) section.remove()
    })
  }

  function start() {
    call('GET').then(function (state) {
      if (!state.enabled) return
      var box = mount()
      if (box) render(box, state)
    }, function () { /* no session, or tokens off: nothing to show */ })
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start)
  else start()
})()
