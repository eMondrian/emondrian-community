// XML/A link: a personal server address with a token in it, for Power BI Desktop's live
// connection, which sends no saved password (auth/README.md, "XML/A links").
//
// Served by the auth gateway and added by it to the entry page (emondrian-locations.conf,
// location = /), and loaded by /account/tokens. Shows nothing when the API refuses: authentication
// off (open access), links turned off, or not logged in.
;(function () {
  'use strict'
  var api = '/account/api/link'

  function el(tag, attrs, text) {
    var node = document.createElement(tag)
    for (var key in attrs || {}) node.setAttribute(key, attrs[key])
    if (text) node.textContent = text
    return node
  }
  function when(iso) {
    return iso ? iso.slice(0, 16).replace('T', ' ') + ' UTC' : ''
  }
  function call(method) {
    return fetch(api, {
      method: method,
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    }).then(function (res) {
      return res.json().catch(function () { return {} }).then(function (data) {
        if (!res.ok) throw new Error(data.error || 'HTTP ' + res.status)
        return data
      })
    })
  }

  // Where it goes: /account/tokens has a slot; the entry page gets a section after "Connect a client"
  function mount() {
    var slot = document.getElementById('xmla-link-slot')
    if (slot) return slot
    // An entry image that has the section itself (data-xmla-link): the gateway adds nothing
    if (document.querySelector('[data-xmla-link]')) return null
    var title = document.getElementById('connect-title')
    var after = title && title.closest('section')
    if (!after) return null
    var section = el('section', { class: 'section', id: 'xmla-link-section', 'aria-labelledby': 'xmla-link-title' })
    section.append(el('h2', { class: 'section__title', id: 'xmla-link-title' }, 'Power BI live connection'))
    var card = el('div', { class: 'card connect' })
    section.append(card)
    after.after(section)
    return card
  }

  function render(box, state, fresh) {
    box.replaceChildren()
    box.append(el('p', {}, 'Power BI Desktop does not send a saved password on a live connection. ' +
      'Use this personal address as the server name instead; it signs you in by itself. ' +
      'Treat it like a password: anyone who has it queries the server as you.'))

    if (fresh) {
      var row = el('div', { class: 'connect__row' })
      var code = el('code', { class: 'connect__url token', id: 'xmla-link-url' }, fresh.url)
      var copy = el('button', { type: 'button', class: 'button' }, 'Copy')
      copy.onclick = function () { navigator.clipboard.writeText(fresh.url) }
      row.append(code, copy)
      box.append(row)
      box.append(el('p', { class: 'hint muted' }, 'Copy it now: it is not shown again. Valid until ' +
        when(fresh.expires) + '.' + (fresh.replaced ? ' Your previous link no longer works.' : '')))
    } else if (state.link && !state.link.expired) {
      box.append(el('p', { class: 'hint muted' }, 'You have a link, valid until ' + when(state.link.expires) +
        (state.link.last_used ? ', last used ' + when(state.link.last_used) : ', not used yet') + '.'))
    } else if (state.link && state.link.expired) {
      box.append(el('p', { class: 'hint muted' }, 'Your link expired on ' + when(state.link.expires) + '.'))
    }

    var actions = el('div', { class: 'connect__row' })
    var get = el('button', { type: 'button', class: 'button' },
      state.link || fresh ? 'Get a new link' : 'Get link')
    get.onclick = function () {
      if ((state.link || fresh) && !confirm('A new link replaces your current one. Reports that use the ' +
          'current link stop working until you change their server address. Continue?')) return
      call('POST').then(function (made) {
        load(box, made)
      }, function (e) { error(box, e) })
    }
    actions.append(get)
    if (state.link || fresh) {
      var revoke = el('button', { type: 'button', class: 'button link' }, 'Revoke')
      revoke.onclick = function () {
        if (!confirm('Revoke your link? Reports that use it stop working within a minute.')) return
        call('DELETE').then(function () { load(box) }, function (e) { error(box, e) })
      }
      actions.append(revoke)
    }
    box.append(actions)
    box.append(el('p', { class: 'hint muted' }, 'Valid for ' + state.days + ' days. ' +
      'Excel and Power BI import mode can use your user name and password, or an access token, instead.'))
  }

  function error(box, e) {
    var p = el('p', { class: 'error' }, e.message)
    box.append(p)
  }

  function load(box, fresh) {
    call('GET').then(function (state) {
      if (!state.enabled) {
        var section = document.getElementById('xmla-link-section')
        ;(section || box).hidden = true
        return
      }
      render(box, state, fresh)
    }, function () {
      var section = document.getElementById('xmla-link-section')
      if (section) section.remove()
    })
  }

  function start() {
    call('GET').then(function (state) {
      if (!state.enabled) {
        var section = document.getElementById('xmla-link-section')
        if (section) section.hidden = true
        return
      }
      var box = mount()
      if (box) render(box, state)
    }, function () { /* no session or no links here: nothing to show */ })
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start)
  else start()
})()
