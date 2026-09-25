/*
 * LX Music 自定义音源 preload 运行环境
 * 移植自 lx-music-mobile 的 user-api-preload.js
 * 运行在 JavaScriptCore 中，通过 __lx_native 与 Swift 桥接。
 */
(function () {
  'use strict'

  var native = function (action, data) {
    return globalThis.__lx_native ? globalThis.__lx_native(action, data === undefined ? null : data) : null
  }

  // ───────────────────────── base64 / hex ─────────────────────────
  var B64CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  function b64Encode(bytes) {
    var len = bytes.length
    var out = ''
    for (var i = 0; i < len; i += 3) {
      var b0 = bytes[i]
      var b1 = i + 1 < len ? bytes[i + 1] : 0
      var b2 = i + 2 < len ? bytes[i + 2] : 0
      out += B64CHARS[b0 >> 2]
      out += B64CHARS[((b0 & 3) << 4) | (b1 >> 4)]
      out += i + 1 < len ? B64CHARS[((b1 & 15) << 2) | (b2 >> 6)] : '='
      out += i + 2 < len ? B64CHARS[b2 & 63] : '='
    }
    return out
  }
  function b64Decode(str) {
    str = String(str).replace(/[^A-Za-z0-9+/=]/g, '')
    var bytes = []
    for (var i = 0; i < str.length; i += 4) {
      var c0 = B64CHARS.indexOf(str.charAt(i))
      var c1 = B64CHARS.indexOf(str.charAt(i + 1))
      var c2 = B64CHARS.indexOf(str.charAt(i + 2))
      var c3 = B64CHARS.indexOf(str.charAt(i + 3))
      bytes.push((c0 << 2) | (c1 >> 4))
      if (c2 !== 64) bytes.push(((c1 & 15) << 4) | (c2 >> 2))
      if (c3 !== 64) bytes.push(((c2 & 3) << 6) | c3)
    }
    return bytes
  }
  var HEXCHARS = '0123456789abcdef'
  function hexEncode(bytes) {
    var out = ''
    for (var i = 0; i < bytes.length; i++) {
      out += HEXCHARS[bytes[i] >> 4] + HEXCHARS[bytes[i] & 15]
    }
    return out
  }
  function hexDecode(str) {
    str = String(str).replace(/[^0-9a-fA-F]/g, '')
    var bytes = []
    for (var i = 0; i < str.length; i += 2) {
      bytes.push(parseInt(str.substr(i, 2), 16))
    }
    return bytes
  }

  // UTF-8 字符串 <-> 字节
  function strToBytes(str) {
    var bytes = []
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i)
      if (code < 0x80) bytes.push(code)
      else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
      } else if (code >= 0xd800 && code <= 0xdbff) {
        var hi = code
        var lo = str.charCodeAt(++i)
        var cp = 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00)
        bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f))
      } else {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
      }
    }
    return bytes
  }
  function bytesToBytesStr(bytes) {
    var out = ''
    for (var i = 0; i < bytes.length; i++) {
      var b = bytes[i]
      if (b < 0x80) out += String.fromCharCode(b)
      else if (b < 0xe0) {
        out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[++i] & 0x3f))
      } else if (b < 0xf0) {
        out += String.fromCharCode(((b & 0xf) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f))
        i += 2
      } else {
        var cp = ((b & 7) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f)
        cp -= 0x10000
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
        i += 3
      }
    }
    return out
  }

  // ───────────────────────── Buffer polyfill ─────────────────────────
  function BufferLike(input, encodingOrOffset, length) {
    var bytes
    if (typeof input === 'string') {
      var enc = (encodingOrOffset || 'utf8').toLowerCase()
      if (enc === 'base64') bytes = b64Decode(input)
      else if (enc === 'hex') bytes = hexDecode(input)
      else if (enc === 'binary' || enc === 'latin1') {
        bytes = []
        for (var k = 0; k < input.length; k++) bytes.push(input.charCodeAt(k) & 0xff)
      } else bytes = strToBytes(input)
    } else if (typeof input === 'number') {
      bytes = new Array(input)
      for (var n = 0; n < input; n++) bytes[n] = 0
    } else if (input && typeof input.length === 'number') {
      bytes = []
      for (var p = 0; p < input.length; p++) bytes.push(input[p] & 0xff)
    } else {
      bytes = []
    }
    var u8 = new Uint8Array(bytes)
    if (typeof encodingOrOffset === 'number' && typeof length === 'number') {
      u8 = u8.subarray(encodingOrOffset, encodingOrOffset + length)
    }
    return u8
  }
  function bufferToString(u8, enc) {
    enc = (enc || 'utf8').toLowerCase()
    var arr = Array.prototype.slice.call(u8)
    if (enc === 'base64') return b64Encode(arr)
    if (enc === 'hex') return hexEncode(arr)
    if (enc === 'binary' || enc === 'latin1') {
      var s = ''
      for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i])
      return s
    }
    return bytesToBytesStr(arr)
  }
  var BufferShim = function (input, enc, len) { return BufferLike(input, enc, len) }
  BufferShim.from = function (input, enc) { return BufferLike(input, enc) }
  BufferShim.alloc = function (size, fill) {
    var u8 = new Uint8Array(size)
    if (fill !== undefined) for (var i = 0; i < size; i++) u8[i] = fill & 0xff
    return u8
  }
  BufferShim.concat = function (list, totalLength) {
    if (totalLength === undefined) {
      totalLength = 0
      for (var i = 0; i < list.length; i++) totalLength += list[i].length
    }
    var out = new Uint8Array(totalLength)
    var offset = 0
    for (var j = 0; j < list.length; j++) {
      out.set(list[j], offset)
      offset += list[j].length
    }
    return out
  }
  BufferShim.isBuffer = function (obj) { return obj instanceof Uint8Array }
  // 给 Uint8Array 注入 toString 编码支持
  var origToString = Uint8Array.prototype.toString
  Uint8Array.prototype.toString = function (enc) {
    if (enc === undefined) return origToString.call(this)
    return bufferToString(this, enc)
  }

  // ───────────────────────── 运行时 ─────────────────────────
  var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' }
  var allSources = ['kw', 'kg', 'tx', 'wy', 'mg', 'local']
  var supportQualitys = {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: []
  }
  var supportActions = {
    kw: ['musicUrl'], kg: ['musicUrl'], tx: ['musicUrl'],
    wy: ['musicUrl'], mg: ['musicUrl'], xm: ['musicUrl'],
    local: ['musicUrl', 'lyric', 'pic']
  }

  function verifyLyricInfo(info) {
    if (typeof info !== 'object' || typeof info.lyric !== 'string') throw new Error('failed')
    if (info.lyric.length > 51200) throw new Error('failed')
    return {
      lyric: info.lyric,
      tlyric: typeof info.tlyric === 'string' && info.tlyric.length < 5120 ? info.tlyric : null,
      rlyric: typeof info.rlyric === 'string' && info.rlyric.length < 5120 ? info.rlyric : null,
      lxlyric: typeof info.lxlyric === 'string' && info.lxlyric.length < 8192 ? info.lxlyric : null
    }
  }

  function Runtime(scriptInfo) {
    this.info = scriptInfo
    this.requestHandler = null
    this.pendingNativeRequests = {}
    this.pendingApiRequests = {}
    this.timers = {}
    this.timerSeq = 1
    this.isInited = false
    this.showedUpdate = false
    this.destroyed = false
  }

  Runtime.prototype.emitLog = function (type, text) {
    native('log', { type: type, msg: text })
  }
  Runtime.prototype.makeConsole = function () {
    var self = this
    function send(type, args) {
      var parts = []
      for (var i = 0; i < args.length; i++) {
        var a = args[i]
        if (typeof a === 'string') parts.push(a)
        else if (a instanceof Error) parts.push(a.stack || a.message)
        else { try { parts.push(JSON.stringify(a)) } catch (e) { parts.push(String(a)) } }
      }
      self.emitLog(type, parts.join(' '))
    }
    return {
      log: function () { send('log', arguments) },
      info: function () { send('info', arguments) },
      warn: function () { send('warn', arguments) },
      error: function () { send('error', arguments) },
      debug: function () { send('log', arguments) }
    }
  }
  Runtime.prototype.setTimeout = function (cb, timeout) {
    var args = Array.prototype.slice.call(arguments, 2)
    var id = this.timerSeq++
    var self = this
    this.timers[id] = {
      interval: 0,
      fire: function () {
        try { cb.apply(null, args) } catch (e) { self.emitLog('error', (e && e.stack) || String(e)) }
      }
    }
    native('setTimeout', { id: id, timeout: Math.max(0, Number(timeout) || 0) })
    return id
  }
  Runtime.prototype.setInterval = function (cb, interval) {
    var args = Array.prototype.slice.call(arguments, 2)
    var id = this.timerSeq++
    var self = this
    var iv = Math.max(0, Number(interval) || 0)
    this.timers[id] = {
      interval: iv,
      fire: function () {
        try { cb.apply(null, args) } catch (e) { self.emitLog('error', (e && e.stack) || String(e)) }
      }
    }
    native('setTimeout', { id: id, timeout: iv })
    return id
  }
  Runtime.prototype.clearTimeout = function (id) { delete this.timers[id] }
  Runtime.prototype.clearInterval = function (id) { delete this.timers[id] }
  Runtime.prototype.fireTimer = function (id) {
    var t = this.timers[id]
    if (!t) return
    t.fire()
    if (t.interval) native('setTimeout', { id: id, timeout: t.interval })
  }

  Runtime.prototype.buildSourceInfo = function (data) {
    if (!data) throw new Error('Missing required parameter init info')
    var sources = {}
    for (var i = 0; i < allSources.length; i++) {
      var source = allSources[i]
      var us = data.sources && data.sources[source]
      if (!us || us.type !== 'music') continue
      var self = this
      sources[source] = {
        type: 'music',
        name: us.name || source,
        actions: supportActions[source].filter(function (a) { return us.actions && us.actions.indexOf(a) !== -1 }),
        qualitys: supportQualitys[source].filter(function (q) { return us.qualitys && us.qualitys.indexOf(q) !== -1 })
      }
    }
    return { sources: sources }
  }

  Runtime.prototype.buildUtils = function () {
    var rt = this
    function toB64(data) {
      if (typeof data === 'string') return b64Encode(strToBytes(data))
      var arr = Array.prototype.slice.call(data)
      return b64Encode(arr)
    }
    return {
      crypto: {
        aesEncrypt: function (buffer, mode, key, iv) {
          var res = native('aes', {
            mode: mode,
            data: toB64(buffer),
            key: toB64(key),
            iv: iv ? toB64(iv) : ''
          })
          return BufferShim.from(res, 'base64')
        },
        rsaEncrypt: function (buffer, key) {
          if (typeof key !== 'string') throw new Error('Invalid RSA key')
          key = key.replace('-----BEGIN PUBLIC KEY-----', '').replace('-----END PUBLIC KEY-----', '')
          var res = native('rsa', { data: toB64(buffer), key: key })
          return BufferShim.from(res, 'base64')
        },
        randomBytes: function (size) {
          var bytes = new Uint8Array(size)
          for (var i = 0; i < size; i++) bytes[i] = Math.floor(Math.random() * 256)
          return bytes
        },
        md5: function (str) {
          if (typeof str !== 'string') throw new Error('param required a string')
          return native('md5', encodeURIComponent(str))
        }
      },
      buffer: {
        from: function (input, enc) { return BufferShim.from(input, enc) },
        bufToString: function (buf, format) { return bufferToString(buf, format) }
      }
    }
  }

  Runtime.prototype.handleNativeResponse = function (data) {
    var target = this.pendingNativeRequests[data.requestKey]
    if (!target) return
    delete this.pendingNativeRequests[data.requestKey]
    if (data.error == null) {
      var resp = data.response || {}
      var body = resp.body
      if (resp.bodyEncoding === 'base64') body = BufferShim.from(body || '', 'base64')
      target(null, {
        statusCode: resp.statusCode,
        statusMessage: resp.statusMessage,
        headers: resp.headers || {},
        body: body
      }, body)
    } else {
      target(new Error(data.error), null, null)
    }
  }

  // Swift 发起的音源请求
  Runtime.prototype.startApiRequest = function (requestKey, params) {
    var rt = this
    if (!this.requestHandler) {
      native('requestResult', { requestKey: requestKey, status: false, error: 'Request event is not defined' })
      return
    }
    Promise.resolve()
      .then(function () { return rt.requestHandler({ source: params.source, action: params.action, info: params.info }) })
      .then(function (response) {
        var result
        if (params.action === 'musicUrl') {
          // 支持字符串或对象返回值，不限制 URL 长度
          var url
          if (typeof response === 'string') {
            url = response
          } else if (response && typeof response === 'object') {
            url = response.url || response.data || response.src || response.songUrl || ''
          } else {
            url = ''
          }
          if (typeof url !== 'string' || !url || !/^https?:/.test(url)) {
            throw new Error('failed')
          }
          result = { source: params.source, action: 'musicUrl', data: { type: params.info.type, url: url } }
        } else if (params.action === 'lyric') {
          result = { source: params.source, action: 'lyric', data: verifyLyricInfo(response) }
        } else if (params.action === 'pic') {
          var picUrl
          if (typeof response === 'string') {
            picUrl = response
          } else if (response && typeof response === 'object') {
            picUrl = response.url || response.data || response.src || ''
          } else {
            picUrl = ''
          }
          if (typeof picUrl !== 'string' || !picUrl || !/^https?:/.test(picUrl)) {
            throw new Error('failed')
          }
          result = { source: params.source, action: 'pic', data: picUrl }
        } else {
          throw new Error('Unknown action')
        }
        native('requestResult', { requestKey: requestKey, status: true, result: result })
      })
      .catch(function (err) {
        native('requestResult', { requestKey: requestKey, status: false, error: (err && err.message) || 'failed' })
      })
  }

  Runtime.prototype.execute = function () {
    var consoleApi = this.makeConsole()
    var rt = this
    var blockedEval = function () { throw new Error('eval is not available') }
    var blockedFunction = function () { throw new Error('Dynamic code execution is not allowed.') }

    var lx = {
      EVENT_NAMES: EVENT_NAMES,
      env: 'mobile',
      version: '2.0.0',
      currentScriptInfo: {
        name: this.info.name,
        description: this.info.description,
        version: this.info.version,
        author: this.info.author,
        homepage: this.info.homepage,
        rawScript: this.info.script
      },
      request: function (url, options, callback) {
        options = options || {}
        var requestKey = 'script_request_' + Math.random().toString(36).slice(2)
        rt.pendingNativeRequests[requestKey] = callback
        native('http', {
          requestKey: requestKey,
          url: url,
          options: {
            method: options.method || 'get',
            timeout: options.timeout || 15000,
            headers: options.headers || {},
            body: options.body !== undefined ? options.body : null,
            form: options.form || null,
            formData: options.formData || null,
            binary: options.binary === true
          }
        })
        return function () {
          if (!rt.pendingNativeRequests[requestKey]) return
          delete rt.pendingNativeRequests[requestKey]
          native('cancelHttp', { requestKey: requestKey })
        }
      },
      send: function (eventName, data) {
        return new Promise(function (resolve, reject) {
          if (eventName === EVENT_NAMES.inited) {
            if (rt.isInited) return reject(new Error('Script is inited'))
            rt.isInited = true
            try {
              var info = rt.buildSourceInfo(data)
              native('inited', { status: true, info: info })
              resolve()
            } catch (e) {
              native('inited', { status: false, error: (e && e.message) || 'Init failed' })
              reject(e)
            }
          } else if (eventName === EVENT_NAMES.updateAlert) {
            if (rt.showedUpdate) return reject(new Error('update alert once'))
            rt.showedUpdate = true
            native('updateAlert', {
              name: rt.info.name,
              log: String((data && data.log) || ''),
              updateUrl: data && typeof data.updateUrl === 'string' ? data.updateUrl : ''
            })
            resolve()
          } else {
            reject(new Error('event not supported: ' + eventName))
          }
        })
      },
      on: function (eventName, handler) {
        if (eventName !== EVENT_NAMES.request) {
          return Promise.reject(new Error('event not supported: ' + eventName))
        }
        rt.requestHandler = handler
        return Promise.resolve()
      },
      utils: this.buildUtils()
    }

    var sandbox = {
      lx: lx,
      console: consoleApi,
      Buffer: BufferShim,
      setTimeout: function (cb, t) { return rt.setTimeout.apply(rt, arguments) },
      clearTimeout: function (id) { return rt.clearTimeout(id) },
      setInterval: function (cb, t) { return rt.setInterval.apply(rt, arguments) },
      clearInterval: function (id) { return rt.clearInterval(id) },
      Function: blockedFunction,
      eval: blockedEval,
      Promise: Promise,
      Uint8Array: Uint8Array,
      Math: Math, Date: Date, JSON: JSON,
      encodeURIComponent: encodeURIComponent, decodeURIComponent: decodeURIComponent,
      encodeURI: encodeURI, decodeURI: decodeURI,
      Error: Error, TypeError: TypeError, Object: Object, Array: Array,
      String: String, Number: Number, Boolean: Boolean, RegExp: RegExp
    }
    sandbox.globalThis = sandbox
    sandbox.window = sandbox
    sandbox.self = sandbox
    sandbox.global = sandbox

    try {
      var runner = new Function(
        'globalThis', 'window', 'self', 'global', 'lx', 'console',
        'Buffer', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
        'Function', 'eval',
        this.info.script + '\n//# sourceURL=' + this.info.id + '.user-api.js'
      )
      runner(
        sandbox, sandbox, sandbox, sandbox, lx, consoleApi,
        BufferShim, sandbox.setTimeout, sandbox.clearTimeout, sandbox.setInterval, sandbox.clearInterval,
        blockedFunction, blockedEval
      )
    } catch (e) {
      native('inited', { status: false, error: (e && e.message) || 'Load script failed' })
    }
  }

  Runtime.prototype.destroy = function () {
    this.destroyed = true
    this.requestHandler = null
    this.pendingNativeRequests = {}
    this.timers = {}
  }

  // ───────────────────────── 对外接口（Swift 调用）─────────────────────────
  var current = null
  globalThis.__lx_load = function (scriptInfo) {
    if (current) current.destroy()
    current = new Runtime(scriptInfo)
    current.execute()
  }
  globalThis.__lx_http_response = function (data) {
    if (current) current.handleNativeResponse(data)
  }
  globalThis.__lx_start_api_request = function (requestKey, params) {
    if (current) current.startApiRequest(requestKey, params)
  }
  globalThis.__lx_fire_timer = function (id) {
    if (current) current.fireTimer(id)
  }
  globalThis.__lx_destroy = function () {
    if (current) current.destroy()
    current = null
  }
})()
