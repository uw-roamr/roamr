// include: shell.js
// include: minimum_runtime_check.js
(function() {
  // "30.0.0" -> 300000
  function humanReadableVersionToPacked(str) {
    str = str.split('-')[0]; // Remove any trailing part from e.g. "12.53.3-alpha"
    var vers = str.split('.').slice(0, 3);
    while(vers.length < 3) vers.push('00');
    vers = vers.map((n, i, arr) => n.padStart(2, '0'));
    return vers.join('');
  }
  // 300000 -> "30.0.0"
  var packedVersionToHumanReadable = n => [n / 10000 | 0, (n / 100 | 0) % 100, n % 100].join('.');

  var TARGET_NOT_SUPPORTED = 2147483647;

  // Note: We use a typeof check here instead of optional chaining using
  // globalThis because older browsers might not have globalThis defined.
  var currentNodeVersion = typeof process !== 'undefined' && process.versions?.node ? humanReadableVersionToPacked(process.versions.node) : TARGET_NOT_SUPPORTED;
  if (currentNodeVersion < 160000) {
    throw new Error(`This emscripten-generated code requires node v${ packedVersionToHumanReadable(160000) } (detected v${packedVersionToHumanReadable(currentNodeVersion)})`);
  }

  var userAgent = typeof navigator !== 'undefined' && navigator.userAgent;
  if (!userAgent) {
    return;
  }

  var currentSafariVersion = userAgent.includes("Safari/") && userAgent.match(/Version\/(\d+\.?\d*\.?\d*)/) ? humanReadableVersionToPacked(userAgent.match(/Version\/(\d+\.?\d*\.?\d*)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentSafariVersion < 150000) {
    throw new Error(`This emscripten-generated code requires Safari v${ packedVersionToHumanReadable(150000) } (detected v${currentSafariVersion})`);
  }

  var currentFirefoxVersion = userAgent.match(/Firefox\/(\d+(?:\.\d+)?)/) ? parseFloat(userAgent.match(/Firefox\/(\d+(?:\.\d+)?)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentFirefoxVersion < 79) {
    throw new Error(`This emscripten-generated code requires Firefox v79 (detected v${currentFirefoxVersion})`);
  }

  var currentChromeVersion = userAgent.match(/Chrome\/(\d+(?:\.\d+)?)/) ? parseFloat(userAgent.match(/Chrome\/(\d+(?:\.\d+)?)/)[1]) : TARGET_NOT_SUPPORTED;
  if (currentChromeVersion < 85) {
    throw new Error(`This emscripten-generated code requires Chrome v85 (detected v${currentChromeVersion})`);
  }
})();

// end include: minimum_runtime_check.js
// The Module object: Our interface to the outside world. We import
// and export values on it. There are various ways Module can be used:
// 1. Not defined. We create it here
// 2. A function parameter, function(moduleArg) => Promise<Module>
// 3. pre-run appended it, var Module = {}; ..generated code..
// 4. External script tag defines var Module.
// We need to check if Module already exists (e.g. case 3 above).
// Substitution will be replaced with actual code on later stage of the build,
// this way Closure Compiler will not mangle it (e.g. case 4. above).
// Note that if you want to run closure, and also to use Module
// after the generated code, you will need to define   var Module = {};
// before the code. Then that object will be used in the code, and you
// can continue to use Module afterwards as well.
var Module = typeof Module != 'undefined' ? Module : {};

// Determine the runtime environment we are in. You can customize this by
// setting the ENVIRONMENT setting at compile time (see settings.js).

// Attempt to auto-detect the environment
var ENVIRONMENT_IS_WEB = !!globalThis.window;
var ENVIRONMENT_IS_WORKER = !!globalThis.WorkerGlobalScope;
// N.b. Electron.js environment is simultaneously a NODE-environment, but
// also a web environment.
var ENVIRONMENT_IS_NODE = globalThis.process?.versions?.node && globalThis.process?.type != 'renderer';
var ENVIRONMENT_IS_SHELL = !ENVIRONMENT_IS_WEB && !ENVIRONMENT_IS_NODE && !ENVIRONMENT_IS_WORKER;

// --pre-jses are emitted after the Module integration code, so that they can
// refer to Module (if they choose; they can also define Module)


var arguments_ = [];
var thisProgram = './this.program';
var quit_ = (status, toThrow) => {
  throw toThrow;
};

// In MODULARIZE mode _scriptName needs to be captured already at the very top of the page immediately when the page is parsed, so it is generated there
// before the page load. In non-MODULARIZE modes generate it here.
var _scriptName = globalThis.document?.currentScript?.src;

if (typeof __filename != 'undefined') { // Node
  _scriptName = __filename;
} else
if (ENVIRONMENT_IS_WORKER) {
  _scriptName = self.location.href;
}

// `/` should be present at the end if `scriptDirectory` is not empty
var scriptDirectory = '';
function locateFile(path) {
  if (Module['locateFile']) {
    return Module['locateFile'](path, scriptDirectory);
  }
  return scriptDirectory + path;
}

// Hooks that are implemented differently in different runtime environments.
var readAsync, readBinary;

if (ENVIRONMENT_IS_NODE) {
  const isNode = globalThis.process?.versions?.node && globalThis.process?.type != 'renderer';
  if (!isNode) throw new Error('not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)');

  // These modules will usually be used on Node.js. Load them eagerly to avoid
  // the complexity of lazy-loading.
  var fs = require('fs');

  scriptDirectory = __dirname + '/';

// include: node_shell_read.js
readBinary = (filename) => {
  // We need to re-wrap `file://` strings to URLs.
  filename = isFileURI(filename) ? new URL(filename) : filename;
  var ret = fs.readFileSync(filename);
  assert(Buffer.isBuffer(ret));
  return ret;
};

readAsync = async (filename, binary = true) => {
  // See the comment in the `readBinary` function.
  filename = isFileURI(filename) ? new URL(filename) : filename;
  var ret = fs.readFileSync(filename, binary ? undefined : 'utf8');
  assert(binary ? Buffer.isBuffer(ret) : typeof ret == 'string');
  return ret;
};
// end include: node_shell_read.js
  if (process.argv.length > 1) {
    thisProgram = process.argv[1].replace(/\\/g, '/');
  }

  arguments_ = process.argv.slice(2);

  // MODULARIZE will export the module in the proper place outside, we don't need to export here
  if (typeof module != 'undefined') {
    module['exports'] = Module;
  }

  quit_ = (status, toThrow) => {
    process.exitCode = status;
    throw toThrow;
  };

} else
if (ENVIRONMENT_IS_SHELL) {

} else

// Note that this includes Node.js workers when relevant (pthreads is enabled).
// Node.js workers are detected as a combination of ENVIRONMENT_IS_WORKER and
// ENVIRONMENT_IS_NODE.
if (ENVIRONMENT_IS_WEB || ENVIRONMENT_IS_WORKER) {
  try {
    scriptDirectory = new URL('.', _scriptName).href; // includes trailing slash
  } catch {
    // Must be a `blob:` or `data:` URL (e.g. `blob:http://site.com/etc/etc`), we cannot
    // infer anything from them.
  }

  if (!(globalThis.window || globalThis.WorkerGlobalScope)) throw new Error('not compiled for this environment (did you build to HTML and try to run it not on the web, or set ENVIRONMENT to something - like node - and run it someplace else - like on the web?)');

  {
// include: web_or_worker_shell_read.js
if (ENVIRONMENT_IS_WORKER) {
    readBinary = (url) => {
      var xhr = new XMLHttpRequest();
      xhr.open('GET', url, false);
      xhr.responseType = 'arraybuffer';
      xhr.send(null);
      return new Uint8Array(/** @type{!ArrayBuffer} */(xhr.response));
    };
  }

  readAsync = async (url) => {
    // Fetch has some additional restrictions over XHR, like it can't be used on a file:// url.
    // See https://github.com/github/fetch/pull/92#issuecomment-140665932
    // Cordova or Electron apps are typically loaded from a file:// url.
    // So use XHR on webview if URL is a file URL.
    if (isFileURI(url)) {
      return new Promise((resolve, reject) => {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.responseType = 'arraybuffer';
        xhr.onload = () => {
          if (xhr.status == 200 || (xhr.status == 0 && xhr.response)) { // file URLs can return 0
            resolve(xhr.response);
            return;
          }
          reject(xhr.status);
        };
        xhr.onerror = reject;
        xhr.send(null);
      });
    }
    var response = await fetch(url, { credentials: 'same-origin' });
    if (response.ok) {
      return response.arrayBuffer();
    }
    throw new Error(response.status + ' : ' + response.url);
  };
// end include: web_or_worker_shell_read.js
  }
} else
{
  throw new Error('environment detection error');
}

var out = console.log.bind(console);
var err = console.error.bind(console);

var IDBFS = 'IDBFS is no longer included by default; build with -lidbfs.js';
var PROXYFS = 'PROXYFS is no longer included by default; build with -lproxyfs.js';
var WORKERFS = 'WORKERFS is no longer included by default; build with -lworkerfs.js';
var FETCHFS = 'FETCHFS is no longer included by default; build with -lfetchfs.js';
var ICASEFS = 'ICASEFS is no longer included by default; build with -licasefs.js';
var JSFILEFS = 'JSFILEFS is no longer included by default; build with -ljsfilefs.js';
var OPFS = 'OPFS is no longer included by default; build with -lopfs.js';

var NODEFS = 'NODEFS is no longer included by default; build with -lnodefs.js';

// perform assertions in shell.js after we set up out() and err(), as otherwise
// if an assertion fails it cannot print the message

assert(!ENVIRONMENT_IS_SHELL, 'shell environment detected but not enabled at build time.  Add `shell` to `-sENVIRONMENT` to enable.');

// end include: shell.js

// include: preamble.js
// === Preamble library stuff ===

// Documentation for the public APIs defined in this file must be updated in:
//    site/source/docs/api_reference/preamble.js.rst
// A prebuilt local version of the documentation is available at:
//    site/build/text/docs/api_reference/preamble.js.txt
// You can also build docs locally as HTML or other formats in site/
// An online HTML version (which may be of a different version of Emscripten)
//    is up at http://kripken.github.io/emscripten-site/docs/api_reference/preamble.js.html

var wasmBinary;

// WASM == 2 includes wasm2js.js separately.
// include: wasm2js.js
// wasm2js.js - enough of a polyfill for the WebAssembly object so that we can load
// wasm2js code that way.

/** @suppress{duplicate, const, checkTypes} */
var WebAssembly = {
  // Note that we do not use closure quoting (this['buffer'], etc.) on these
  // functions, as they are just meant for internal use. In other words, this is
  // not a fully general polyfill.
  /** @constructor */
  Memory: function(opts) {
    this.buffer = new ArrayBuffer(opts['initial'] * 65536);
  },

  Module: function(binary) {
    // TODO: use the binary and info somehow - right now the wasm2js output is embedded in
    // the main JS
  },

  /** @constructor */
  Instance: function(module, info) {
    // TODO: use the module somehow - right now the wasm2js output is embedded in
    // the main JS
    // This will be replaced by the actual wasm2js code.
    this.exports = (
function instantiate(info) {
function Table(ret) {
  // grow method not included; table is not growable
  ret.set = function(i, func) {
    this[i] = func;
  };
  ret.get = function(i) {
    return this[i];
  };
  return ret;
}

  var bufferView;
  var base64ReverseLookup = new Uint8Array(123/*'z'+1*/);
  for (var i = 25; i >= 0; --i) {
    base64ReverseLookup[48+i] = 52+i; // '0-9'
    base64ReverseLookup[65+i] = i; // 'A-Z'
    base64ReverseLookup[97+i] = 26+i; // 'a-z'
  }
  base64ReverseLookup[43] = 62; // '+'
  base64ReverseLookup[47] = 63; // '/'
  /** @noinline Inlining this function would mean expanding the base64 string 4x times in the source code, which Closure seems to be happy to do. */
  function base64DecodeToExistingUint8Array(uint8Array, offset, b64) {
    var b1, b2, i = 0, j = offset, bLength = b64.length, end = offset + (bLength*3>>2) - (b64[bLength-2] == '=') - (b64[bLength-1] == '=');
    for (; i < bLength; i += 4) {
      b1 = base64ReverseLookup[b64.charCodeAt(i+1)];
      b2 = base64ReverseLookup[b64.charCodeAt(i+2)];
      uint8Array[j++] = base64ReverseLookup[b64.charCodeAt(i)] << 2 | b1 >> 4;
      if (j < end) uint8Array[j++] = b1 << 4 | b2 >> 2;
      if (j < end) uint8Array[j++] = b2 << 6 | base64ReverseLookup[b64.charCodeAt(i+3)];
    }
    return uint8Array;
  }
function initActiveSegments(imports) {
  base64DecodeToExistingUint8Array(bufferView, 65536, "LSsgICAwWDB4AC0wWCswWCAwWC0weCsweCAweABVbmtub3duIGVycm9yAG5hbgBpbmYATkFOAElORgAuAChudWxsKQBNZW1vcnkgYWxsb2NhdGlvbiBzdWNjZXNzZnVsLgoATWVtb3J5IGFsbG9jYXRpb24gZmFpbGVkLgoAAAAZAAsAGRkZAAAAAAUAAAAAAAAJAAAAAAsAAAAAAAAAABkACgoZGRkDCgcAAQAJCxgAAAkGCwAACwAGGQAAABkZGQAAAAAAAAAAAAAAAAAAAAAOAAAAAAAAAAAZAAsNGRkZAA0AAAIACQ4AAAAJAA4AAA4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAEwAAAAATAAAAAAkMAAAAAAAMAAAMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA8AAAAEDwAAAAAJEAAAAAAAEAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASAAAAAAAAAAAAAAARAAAAABEAAAAACRIAAAAAABIAABIAABoAAAAaGhoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGgAAABoaGgAAAAAAAAkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQAAAAAAAAAAAAAABcAAAAAFwAAAAAJFAAAAAAAFAAAFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWAAAAAAAAAAAAAAAVAAAAABUAAAAACRYAAAAAABYAABYAADAxMjM0NTY3ODlBQkNERUYAAKACTgDrAacFfgUgAXUGGAOGBPoAuQMsA/0FtwGKAXoDvAQeAMwGogA9A0kD1wEABAgAkwYIAY8CBgIqBl8CtwL6AlgD2QT9BsoCvQXhBc0F3AIQBkACeAB9AmcDYQTsAOUDCgXUAMwDPgZPAnYBmAOvBAAARAAQAq4ArgNgAPoBdwQhBesEKwBgAUEBkgCpBqMBbgJOAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABMEAAAAAAAAAAAqAgAAAAAAAAAAAAAAAAAAAAAAAAAAJwQ5BEgEAAAAAAAAAAAAAAAAAAAAAJIEAAAAAAAAAAAAAAAAAAAAAAAAOAVSBWAFUwYAAMoBAAAAAAAAAAC7BtsG6wYQBysHOwdQB1N1Y2Nlc3MASWxsZWdhbCBieXRlIHNlcXVlbmNlAERvbWFpbiBlcnJvcgBSZXN1bHQgbm90IHJlcHJlc2VudGFibGUATm90IGEgdHR5AFBlcm1pc3Npb24gZGVuaWVkAE9wZXJhdGlvbiBub3QgcGVybWl0dGVkAE5vIHN1Y2ggZmlsZSBvciBkaXJlY3RvcnkATm8gc3VjaCBwcm9jZXNzAEZpbGUgZXhpc3RzAFZhbHVlIHRvbyBsYXJnZSBmb3IgZGVmaW5lZCBkYXRhIHR5cGUATm8gc3BhY2UgbGVmdCBvbiBkZXZpY2UAT3V0IG9mIG1lbW9yeQBSZXNvdXJjZSBidXN5AEludGVycnVwdGVkIHN5c3RlbSBjYWxsAFJlc291cmNlIHRlbXBvcmFyaWx5IHVuYXZhaWxhYmxlAEludmFsaWQgc2VlawBDcm9zcy1kZXZpY2UgbGluawBSZWFkLW9ubHkgZmlsZSBzeXN0ZW0ARGlyZWN0b3J5IG5vdCBlbXB0eQBDb25uZWN0aW9uIHJlc2V0IGJ5IHBlZXIAT3BlcmF0aW9uIHRpbWVkIG91dABDb25uZWN0aW9uIHJlZnVzZWQASG9zdCBpcyBkb3duAEhvc3QgaXMgdW5yZWFjaGFibGUAQWRkcmVzcyBpbiB1c2UAQnJva2VuIHBpcGUASS9PIGVycm9yAE5vIHN1Y2ggZGV2aWNlIG9yIGFkZHJlc3MAQmxvY2sgZGV2aWNlIHJlcXVpcmVkAE5vIHN1Y2ggZGV2aWNlAE5vdCBhIGRpcmVjdG9yeQBJcyBhIGRpcmVjdG9yeQBUZXh0IGZpbGUgYnVzeQBFeGVjIGZvcm1hdCBlcnJvcgBJbnZhbGlkIGFyZ3VtZW50AEFyZ3VtZW50IGxpc3QgdG9vIGxvbmcAU3ltYm9saWMgbGluayBsb29wAEZpbGVuYW1lIHRvbyBsb25nAFRvbyBtYW55IG9wZW4gZmlsZXMgaW4gc3lzdGVtAE5vIGZpbGUgZGVzY3JpcHRvcnMgYXZhaWxhYmxlAEJhZCBmaWxlIGRlc2NyaXB0b3IATm8gY2hpbGQgcHJvY2VzcwBCYWQgYWRkcmVzcwBGaWxlIHRvbyBsYXJnZQBUb28gbWFueSBsaW5rcwBObyBsb2NrcyBhdmFpbGFibGUAUmVzb3VyY2UgZGVhZGxvY2sgd291bGQgb2NjdXIAU3RhdGUgbm90IHJlY292ZXJhYmxlAE93bmVyIGRpZWQAT3BlcmF0aW9uIGNhbmNlbGVkAEZ1bmN0aW9uIG5vdCBpbXBsZW1lbnRlZABObyBtZXNzYWdlIG9mIGRlc2lyZWQgdHlwZQBJZGVudGlmaWVyIHJlbW92ZWQARGV2aWNlIG5vdCBhIHN0cmVhbQBObyBkYXRhIGF2YWlsYWJsZQBEZXZpY2UgdGltZW91dABPdXQgb2Ygc3RyZWFtcyByZXNvdXJjZXMATGluayBoYXMgYmVlbiBzZXZlcmVkAFByb3RvY29sIGVycm9yAEJhZCBtZXNzYWdlAEZpbGUgZGVzY3JpcHRvciBpbiBiYWQgc3RhdGUATm90IGEgc29ja2V0AERlc3RpbmF0aW9uIGFkZHJlc3MgcmVxdWlyZWQATWVzc2FnZSB0b28gbGFyZ2UAUHJvdG9jb2wgd3JvbmcgdHlwZSBmb3Igc29ja2V0AFByb3RvY29sIG5vdCBhdmFpbGFibGUAUHJvdG9jb2wgbm90IHN1cHBvcnRlZABTb2NrZXQgdHlwZSBub3Qgc3VwcG9ydGVkAE5vdCBzdXBwb3J0ZWQAUHJvdG9jb2wgZmFtaWx5IG5vdCBzdXBwb3J0ZWQAQWRkcmVzcyBmYW1pbHkgbm90IHN1cHBvcnRlZCBieSBwcm90b2NvbABBZGRyZXNzIG5vdCBhdmFpbGFibGUATmV0d29yayBpcyBkb3duAE5ldHdvcmsgdW5yZWFjaGFibGUAQ29ubmVjdGlvbiByZXNldCBieSBuZXR3b3JrAENvbm5lY3Rpb24gYWJvcnRlZABObyBidWZmZXIgc3BhY2UgYXZhaWxhYmxlAFNvY2tldCBpcyBjb25uZWN0ZWQAU29ja2V0IG5vdCBjb25uZWN0ZWQAQ2Fubm90IHNlbmQgYWZ0ZXIgc29ja2V0IHNodXRkb3duAE9wZXJhdGlvbiBhbHJlYWR5IGluIHByb2dyZXNzAE9wZXJhdGlvbiBpbiBwcm9ncmVzcwBTdGFsZSBmaWxlIGhhbmRsZQBSZW1vdGUgSS9PIGVycm9yAFF1b3RhIGV4Y2VlZGVkAE5vIG1lZGl1bSBmb3VuZABXcm9uZyBtZWRpdW0gdHlwZQBNdWx0aWhvcCBhdHRlbXB0ZWQAUmVxdWlyZWQga2V5IG5vdCBhdmFpbGFibGUAS2V5IGhhcyBleHBpcmVkAEtleSBoYXMgYmVlbiByZXZva2VkAEtleSB3YXMgcmVqZWN0ZWQgYnkgc2VydmljZQA=");
  base64DecodeToExistingUint8Array(bufferView, 68352, "BQAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAMAAAA4DAEAAAQAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAP////8KAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsBAAAgAAAFAAAAAAAAAAAAAAAGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAABwAAAAgRAQAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAA//////////8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACYCwEAABMBAA==");
}

  var scratchBuffer = new ArrayBuffer(16);
  var i32ScratchView = new Int32Array(scratchBuffer);
  var f32ScratchView = new Float32Array(scratchBuffer);
  var f64ScratchView = new Float64Array(scratchBuffer);
  
  function wasm2js_scratch_load_i32(index) {
    return i32ScratchView[index];
  }
      
  function wasm2js_scratch_store_i32(index, value) {
    i32ScratchView[index] = value;
  }
      
  function wasm2js_scratch_load_f64() {
    return f64ScratchView[0];
  }
      
  function wasm2js_scratch_store_f64(value) {
    f64ScratchView[0] = value;
  }
      
  function wasm2js_memory_copy(dest, source, size) {
    // TODO: traps on invalid things
    bufferView.copyWithin(dest, source, source + size);
  }
      
  function wasm2js_memory_fill(dest, value, size) {
    dest = dest >>> 0;
    size = size >>> 0;
    if (dest + size > bufferView.length) throw "trap: invalid memory.fill";
    bufferView.fill(value, dest, dest + size);
  }
      function wasm2js_trap() { throw new Error('abort'); }

function asmFunc(imports) {
 var buffer = new ArrayBuffer(67108864);
 var HEAP8 = new Int8Array(buffer);
 var HEAP16 = new Int16Array(buffer);
 var HEAP32 = new Int32Array(buffer);
 var HEAPU8 = new Uint8Array(buffer);
 var HEAPU16 = new Uint16Array(buffer);
 var HEAPU32 = new Uint32Array(buffer);
 var HEAPF32 = new Float32Array(buffer);
 var HEAPF64 = new Float64Array(buffer);
 var Math_imul = Math.imul;
 var Math_fround = Math.fround;
 var Math_abs = Math.abs;
 var Math_clz32 = Math.clz32;
 var Math_min = Math.min;
 var Math_max = Math.max;
 var Math_floor = Math.floor;
 var Math_ceil = Math.ceil;
 var Math_trunc = Math.trunc;
 var Math_sqrt = Math.sqrt;
 var wasi_snapshot_preview1 = imports.wasi_snapshot_preview1;
 var fimport$0 = wasi_snapshot_preview1.fd_write;
 var env = imports.env;
 var fimport$1 = env._abort_js;
 var fimport$2 = wasi_snapshot_preview1.fd_close;
 var fimport$3 = env.emscripten_resize_heap;
 var fimport$4 = wasi_snapshot_preview1.fd_seek;
 var global$0 = 65536;
 var global$1 = 0;
 var global$2 = 0;
 var global$3 = 0;
 var __wasm_intrinsics_temp_i64 = 0;
 var __wasm_intrinsics_temp_i64$hi = 0;
 var i64toi32_i32$HIGH_BITS = 0;
 // EMSCRIPTEN_START_FUNCS
;
 function $0() {
  $52();
  $39();
 }
 
 function $1() {
  var $0_1 = 0, $20_1 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  $0_1 = global$0 - 16 | 0;
  global$0 = $0_1;
  HEAP32[($0_1 + 12 | 0) >> 2] = 0;
  (wasm2js_i32$0 = $0_1, wasm2js_i32$1 = $47(10485760 | 0) | 0), HEAP32[(wasm2js_i32$0 + 8 | 0) >> 2] = wasm2js_i32$1;
  block1 : {
   block : {
    if (!((HEAP32[($0_1 + 8 | 0) >> 2] | 0 | 0) != (0 | 0) & 1 | 0)) {
     break block
    }
    $3(65604 | 0, 0 | 0) | 0;
    $49(HEAP32[($0_1 + 8 | 0) >> 2] | 0 | 0);
    break block1;
   }
   $3(65635 | 0, 0 | 0) | 0;
  }
  global$0 = $0_1 + 16 | 0;
  return 0 | 0;
 }
 
 function $2($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  return $1() | 0 | 0;
 }
 
 function $3($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  var $2_1 = 0;
  $2_1 = global$0 - 16 | 0;
  global$0 = $2_1;
  HEAP32[($2_1 + 12 | 0) >> 2] = $1_1;
  $1_1 = $31(68352 | 0, $0_1 | 0, $1_1 | 0) | 0;
  global$0 = $2_1 + 16 | 0;
  return $1_1 | 0;
 }
 
 function $4($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $4_1 = 0, $3_1 = 0, $5_1 = 0, $8_1 = 0, $6_1 = 0, $7_1 = 0, $9_1 = 0;
  $3_1 = global$0 - 32 | 0;
  global$0 = $3_1;
  $4_1 = HEAP32[($0_1 + 28 | 0) >> 2] | 0;
  HEAP32[($3_1 + 16 | 0) >> 2] = $4_1;
  $5_1 = HEAP32[($0_1 + 20 | 0) >> 2] | 0;
  HEAP32[($3_1 + 28 | 0) >> 2] = $2_1;
  HEAP32[($3_1 + 24 | 0) >> 2] = $1_1;
  $1_1 = $5_1 - $4_1 | 0;
  HEAP32[($3_1 + 20 | 0) >> 2] = $1_1;
  $6_1 = $1_1 + $2_1 | 0;
  $4_1 = $3_1 + 16 | 0;
  $7_1 = 2;
  block5 : {
   block4 : {
    block2 : {
     block1 : {
      block : {
       if (!($35(fimport$0(HEAP32[($0_1 + 60 | 0) >> 2] | 0 | 0, $3_1 + 16 | 0 | 0, 2 | 0, $3_1 + 12 | 0 | 0) | 0 | 0) | 0)) {
        break block
       }
       $5_1 = $4_1;
       break block1;
      }
      label : while (1) {
       $1_1 = HEAP32[($3_1 + 12 | 0) >> 2] | 0;
       if (($6_1 | 0) == ($1_1 | 0)) {
        break block2
       }
       block3 : {
        if (($1_1 | 0) > (-1 | 0)) {
         break block3
        }
        $5_1 = $4_1;
        break block4;
       }
       $8_1 = HEAP32[($4_1 + 4 | 0) >> 2] | 0;
       $9_1 = $1_1 >>> 0 > $8_1 >>> 0;
       $5_1 = $4_1 + ($9_1 ? 8 : 0) | 0;
       $8_1 = $1_1 - ($9_1 ? $8_1 : 0) | 0;
       HEAP32[$5_1 >> 2] = (HEAP32[$5_1 >> 2] | 0) + $8_1 | 0;
       $4_1 = $4_1 + ($9_1 ? 12 : 4) | 0;
       HEAP32[$4_1 >> 2] = (HEAP32[$4_1 >> 2] | 0) - $8_1 | 0;
       $6_1 = $6_1 - $1_1 | 0;
       $4_1 = $5_1;
       $7_1 = $7_1 - $9_1 | 0;
       if (!($35(fimport$0(HEAP32[($0_1 + 60 | 0) >> 2] | 0 | 0, $4_1 | 0, $7_1 | 0, $3_1 + 12 | 0 | 0) | 0 | 0) | 0)) {
        continue label
       }
       break label;
      };
     }
     if (($6_1 | 0) != (-1 | 0)) {
      break block4
     }
    }
    $1_1 = HEAP32[($0_1 + 44 | 0) >> 2] | 0;
    HEAP32[($0_1 + 28 | 0) >> 2] = $1_1;
    HEAP32[($0_1 + 20 | 0) >> 2] = $1_1;
    HEAP32[($0_1 + 16 | 0) >> 2] = $1_1 + (HEAP32[($0_1 + 48 | 0) >> 2] | 0) | 0;
    $1_1 = $2_1;
    break block5;
   }
   $1_1 = 0;
   HEAP32[($0_1 + 28 | 0) >> 2] = 0;
   HEAP32[($0_1 + 16 | 0) >> 2] = 0;
   HEAP32[($0_1 + 20 | 0) >> 2] = 0;
   HEAP32[$0_1 >> 2] = HEAP32[$0_1 >> 2] | 0 | 32 | 0;
   if (($7_1 | 0) == (2 | 0)) {
    break block5
   }
   $1_1 = $2_1 - (HEAP32[($5_1 + 4 | 0) >> 2] | 0) | 0;
  }
  global$0 = $3_1 + 32 | 0;
  return $1_1 | 0;
 }
 
 function $5($0_1) {
  $0_1 = $0_1 | 0;
  return 0 | 0;
 }
 
 function $6($0_1, $1_1, $1$hi, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  i64toi32_i32$HIGH_BITS = 0;
  return 0 | 0;
 }
 
 function $7($0_1) {
  $0_1 = $0_1 | 0;
  return 1 | 0;
 }
 
 function $8($0_1) {
  $0_1 = $0_1 | 0;
 }
 
 function $9($0_1) {
  $0_1 = $0_1 | 0;
 }
 
 function $10($0_1) {
  $0_1 = $0_1 | 0;
 }
 
 function $11() {
  $9(69688 | 0);
  return 69692 | 0;
 }
 
 function $12() {
  $10(69688 | 0);
 }
 
 function $13($0_1) {
  $0_1 = $0_1 | 0;
  var $1_1 = 0;
  $1_1 = HEAP32[($0_1 + 72 | 0) >> 2] | 0;
  HEAP32[($0_1 + 72 | 0) >> 2] = $1_1 + -1 | 0 | $1_1 | 0;
  block : {
   $1_1 = HEAP32[$0_1 >> 2] | 0;
   if (!($1_1 & 8 | 0)) {
    break block
   }
   HEAP32[$0_1 >> 2] = $1_1 | 32 | 0;
   return -1 | 0;
  }
  HEAP32[($0_1 + 4 | 0) >> 2] = 0;
  HEAP32[($0_1 + 8 | 0) >> 2] = 0;
  $1_1 = HEAP32[($0_1 + 44 | 0) >> 2] | 0;
  HEAP32[($0_1 + 28 | 0) >> 2] = $1_1;
  HEAP32[($0_1 + 20 | 0) >> 2] = $1_1;
  HEAP32[($0_1 + 16 | 0) >> 2] = $1_1 + (HEAP32[($0_1 + 48 | 0) >> 2] | 0) | 0;
  return 0 | 0;
 }
 
 function $14($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $3_1 = 0, $4_1 = 0;
  $3_1 = ($2_1 | 0) != (0 | 0);
  block2 : {
   block1 : {
    block : {
     if (!($0_1 & 3 | 0)) {
      break block
     }
     if (!$2_1) {
      break block
     }
     $4_1 = $1_1 & 255 | 0;
     label : while (1) {
      if ((HEAPU8[$0_1 >> 0] | 0 | 0) == ($4_1 | 0)) {
       break block1
      }
      $2_1 = $2_1 + -1 | 0;
      $3_1 = ($2_1 | 0) != (0 | 0);
      $0_1 = $0_1 + 1 | 0;
      if (!($0_1 & 3 | 0)) {
       break block
      }
      if ($2_1) {
       continue label
      }
      break label;
     };
    }
    if (!$3_1) {
     break block2
    }
    block3 : {
     if ((HEAPU8[$0_1 >> 0] | 0 | 0) == ($1_1 & 255 | 0 | 0)) {
      break block3
     }
     if ($2_1 >>> 0 < 4 >>> 0) {
      break block3
     }
     $4_1 = Math_imul($1_1 & 255 | 0, 16843009);
     label1 : while (1) {
      $3_1 = (HEAP32[$0_1 >> 2] | 0) ^ $4_1 | 0;
      if (((16843008 - $3_1 | 0 | $3_1 | 0) & -2139062144 | 0 | 0) != (-2139062144 | 0)) {
       break block1
      }
      $0_1 = $0_1 + 4 | 0;
      $2_1 = $2_1 + -4 | 0;
      if ($2_1 >>> 0 > 3 >>> 0) {
       continue label1
      }
      break label1;
     };
    }
    if (!$2_1) {
     break block2
    }
   }
   $3_1 = $1_1 & 255 | 0;
   label2 : while (1) {
    block4 : {
     if ((HEAPU8[$0_1 >> 0] | 0 | 0) != ($3_1 | 0)) {
      break block4
     }
     return $0_1 | 0;
    }
    $0_1 = $0_1 + 1 | 0;
    $2_1 = $2_1 + -1 | 0;
    if ($2_1) {
     continue label2
    }
    break label2;
   };
  }
  return 0 | 0;
 }
 
 function $15($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  var $2_1 = 0;
  $2_1 = $14($0_1 | 0, 0 | 0, $1_1 | 0) | 0;
  return ($2_1 ? $2_1 - $0_1 | 0 : $1_1) | 0;
 }
 
 function $16() {
  return 69696 | 0;
 }
 
 function $17($0_1, $1_1) {
  $0_1 = +$0_1;
  $1_1 = $1_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$3 = 0, $3_1 = 0, i64toi32_i32$2 = 0, i64toi32_i32$4 = 0, $2_1 = 0, $10_1 = 0, $2$hi = 0;
  block : {
   wasm2js_scratch_store_f64(+$0_1);
   i64toi32_i32$0 = wasm2js_scratch_load_i32(1 | 0) | 0;
   $2_1 = wasm2js_scratch_load_i32(0 | 0) | 0;
   $2$hi = i64toi32_i32$0;
   i64toi32_i32$2 = $2_1;
   i64toi32_i32$1 = 0;
   i64toi32_i32$3 = 52;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$1 = 0;
    $10_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
   } else {
    i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
    $10_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
   }
   $3_1 = $10_1 & 2047 | 0;
   if (($3_1 | 0) == (2047 | 0)) {
    break block
   }
   block1 : {
    if ($3_1) {
     break block1
    }
    block3 : {
     block2 : {
      if ($0_1 != 0.0) {
       break block2
      }
      $3_1 = 0;
      break block3;
     }
     $0_1 = +$17(+($0_1 * 18446744073709551615.0), $1_1 | 0);
     $3_1 = (HEAP32[$1_1 >> 2] | 0) + -64 | 0;
    }
    HEAP32[$1_1 >> 2] = $3_1;
    return +$0_1;
   }
   HEAP32[$1_1 >> 2] = $3_1 + -1022 | 0;
   i64toi32_i32$1 = $2$hi;
   i64toi32_i32$0 = $2_1;
   i64toi32_i32$2 = -2146435073;
   i64toi32_i32$3 = -1;
   i64toi32_i32$2 = i64toi32_i32$1 & i64toi32_i32$2 | 0;
   i64toi32_i32$1 = i64toi32_i32$0 & i64toi32_i32$3 | 0;
   i64toi32_i32$0 = 1071644672;
   i64toi32_i32$3 = 0;
   i64toi32_i32$0 = i64toi32_i32$2 | i64toi32_i32$0 | 0;
   wasm2js_scratch_store_i32(0 | 0, i64toi32_i32$1 | i64toi32_i32$3 | 0 | 0);
   wasm2js_scratch_store_i32(1 | 0, i64toi32_i32$0 | 0);
   $0_1 = +wasm2js_scratch_load_f64();
  }
  return +$0_1;
 }
 
 function $18($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  if ($2_1) {
   wasm2js_memory_copy($0_1, $1_1, $2_1)
  }
  return $0_1 | 0;
 }
 
 function $19($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $3_1 = 0, $4_1 = 0, $5_1 = 0;
  block : {
   if ($2_1 >>> 0 < 512 >>> 0) {
    break block
   }
   return $18($0_1 | 0, $1_1 | 0, $2_1 | 0) | 0 | 0;
  }
  $3_1 = $0_1 + $2_1 | 0;
  block6 : {
   block1 : {
    if (($1_1 ^ $0_1 | 0) & 3 | 0) {
     break block1
    }
    block3 : {
     block2 : {
      if ($0_1 & 3 | 0) {
       break block2
      }
      $2_1 = $0_1;
      break block3;
     }
     block4 : {
      if ($2_1) {
       break block4
      }
      $2_1 = $0_1;
      break block3;
     }
     $2_1 = $0_1;
     label : while (1) {
      HEAP8[$2_1 >> 0] = HEAPU8[$1_1 >> 0] | 0;
      $1_1 = $1_1 + 1 | 0;
      $2_1 = $2_1 + 1 | 0;
      if (!($2_1 & 3 | 0)) {
       break block3
      }
      if ($2_1 >>> 0 < $3_1 >>> 0) {
       continue label
      }
      break label;
     };
    }
    $4_1 = $3_1 & -4 | 0;
    block5 : {
     if ($3_1 >>> 0 < 64 >>> 0) {
      break block5
     }
     $5_1 = $4_1 + -64 | 0;
     if ($2_1 >>> 0 > $5_1 >>> 0) {
      break block5
     }
     label1 : while (1) {
      HEAP32[$2_1 >> 2] = HEAP32[$1_1 >> 2] | 0;
      HEAP32[($2_1 + 4 | 0) >> 2] = HEAP32[($1_1 + 4 | 0) >> 2] | 0;
      HEAP32[($2_1 + 8 | 0) >> 2] = HEAP32[($1_1 + 8 | 0) >> 2] | 0;
      HEAP32[($2_1 + 12 | 0) >> 2] = HEAP32[($1_1 + 12 | 0) >> 2] | 0;
      HEAP32[($2_1 + 16 | 0) >> 2] = HEAP32[($1_1 + 16 | 0) >> 2] | 0;
      HEAP32[($2_1 + 20 | 0) >> 2] = HEAP32[($1_1 + 20 | 0) >> 2] | 0;
      HEAP32[($2_1 + 24 | 0) >> 2] = HEAP32[($1_1 + 24 | 0) >> 2] | 0;
      HEAP32[($2_1 + 28 | 0) >> 2] = HEAP32[($1_1 + 28 | 0) >> 2] | 0;
      HEAP32[($2_1 + 32 | 0) >> 2] = HEAP32[($1_1 + 32 | 0) >> 2] | 0;
      HEAP32[($2_1 + 36 | 0) >> 2] = HEAP32[($1_1 + 36 | 0) >> 2] | 0;
      HEAP32[($2_1 + 40 | 0) >> 2] = HEAP32[($1_1 + 40 | 0) >> 2] | 0;
      HEAP32[($2_1 + 44 | 0) >> 2] = HEAP32[($1_1 + 44 | 0) >> 2] | 0;
      HEAP32[($2_1 + 48 | 0) >> 2] = HEAP32[($1_1 + 48 | 0) >> 2] | 0;
      HEAP32[($2_1 + 52 | 0) >> 2] = HEAP32[($1_1 + 52 | 0) >> 2] | 0;
      HEAP32[($2_1 + 56 | 0) >> 2] = HEAP32[($1_1 + 56 | 0) >> 2] | 0;
      HEAP32[($2_1 + 60 | 0) >> 2] = HEAP32[($1_1 + 60 | 0) >> 2] | 0;
      $1_1 = $1_1 + 64 | 0;
      $2_1 = $2_1 + 64 | 0;
      if ($2_1 >>> 0 <= $5_1 >>> 0) {
       continue label1
      }
      break label1;
     };
    }
    if ($2_1 >>> 0 >= $4_1 >>> 0) {
     break block6
    }
    label2 : while (1) {
     HEAP32[$2_1 >> 2] = HEAP32[$1_1 >> 2] | 0;
     $1_1 = $1_1 + 4 | 0;
     $2_1 = $2_1 + 4 | 0;
     if ($2_1 >>> 0 < $4_1 >>> 0) {
      continue label2
     }
     break block6;
    };
   }
   block7 : {
    if ($3_1 >>> 0 >= 4 >>> 0) {
     break block7
    }
    $2_1 = $0_1;
    break block6;
   }
   block8 : {
    if ($2_1 >>> 0 >= 4 >>> 0) {
     break block8
    }
    $2_1 = $0_1;
    break block6;
   }
   $4_1 = $3_1 + -4 | 0;
   $2_1 = $0_1;
   label3 : while (1) {
    HEAP8[$2_1 >> 0] = HEAPU8[$1_1 >> 0] | 0;
    HEAP8[($2_1 + 1 | 0) >> 0] = HEAPU8[($1_1 + 1 | 0) >> 0] | 0;
    HEAP8[($2_1 + 2 | 0) >> 0] = HEAPU8[($1_1 + 2 | 0) >> 0] | 0;
    HEAP8[($2_1 + 3 | 0) >> 0] = HEAPU8[($1_1 + 3 | 0) >> 0] | 0;
    $1_1 = $1_1 + 4 | 0;
    $2_1 = $2_1 + 4 | 0;
    if ($2_1 >>> 0 <= $4_1 >>> 0) {
     continue label3
    }
    break label3;
   };
  }
  block9 : {
   if ($2_1 >>> 0 >= $3_1 >>> 0) {
    break block9
   }
   label4 : while (1) {
    HEAP8[$2_1 >> 0] = HEAPU8[$1_1 >> 0] | 0;
    $1_1 = $1_1 + 1 | 0;
    $2_1 = $2_1 + 1 | 0;
    if (($2_1 | 0) != ($3_1 | 0)) {
     continue label4
    }
    break label4;
   };
  }
  return $0_1 | 0;
 }
 
 function $20($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $3_1 = 0, $4_1 = 0, $5_1 = 0;
  block1 : {
   block : {
    $3_1 = HEAP32[($2_1 + 16 | 0) >> 2] | 0;
    if ($3_1) {
     break block
    }
    $4_1 = 0;
    if ($13($2_1 | 0) | 0) {
     break block1
    }
    $3_1 = HEAP32[($2_1 + 16 | 0) >> 2] | 0;
   }
   block2 : {
    $4_1 = HEAP32[($2_1 + 20 | 0) >> 2] | 0;
    if ($1_1 >>> 0 <= ($3_1 - $4_1 | 0) >>> 0) {
     break block2
    }
    return FUNCTION_TABLE[HEAP32[($2_1 + 36 | 0) >> 2] | 0 | 0]($2_1, $0_1, $1_1) | 0 | 0;
   }
   block5 : {
    block3 : {
     if ((HEAP32[($2_1 + 80 | 0) >> 2] | 0 | 0) < (0 | 0)) {
      break block3
     }
     if (!$1_1) {
      break block3
     }
     $3_1 = $1_1;
     block4 : {
      label : while (1) {
       $5_1 = $0_1 + $3_1 | 0;
       if ((HEAPU8[($5_1 + -1 | 0) >> 0] | 0 | 0) == (10 | 0)) {
        break block4
       }
       $3_1 = $3_1 + -1 | 0;
       if (!$3_1) {
        break block3
       }
       continue label;
      };
     }
     $4_1 = FUNCTION_TABLE[HEAP32[($2_1 + 36 | 0) >> 2] | 0 | 0]($2_1, $0_1, $3_1) | 0;
     if ($4_1 >>> 0 < $3_1 >>> 0) {
      break block1
     }
     $1_1 = $1_1 - $3_1 | 0;
     $4_1 = HEAP32[($2_1 + 20 | 0) >> 2] | 0;
     break block5;
    }
    $5_1 = $0_1;
    $3_1 = 0;
   }
   $19($4_1 | 0, $5_1 | 0, $1_1 | 0) | 0;
   HEAP32[($2_1 + 20 | 0) >> 2] = (HEAP32[($2_1 + 20 | 0) >> 2] | 0) + $1_1 | 0;
   $4_1 = $3_1 + $1_1 | 0;
  }
  return $4_1 | 0;
 }
 
 function $21($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $3_1 = 0, i64toi32_i32$0 = 0, $4_1 = 0, i64toi32_i32$1 = 0, $6_1 = 0, $5_1 = 0, $6$hi = 0;
  block : {
   if (!$2_1) {
    break block
   }
   HEAP8[$0_1 >> 0] = $1_1;
   $3_1 = $0_1 + $2_1 | 0;
   HEAP8[($3_1 + -1 | 0) >> 0] = $1_1;
   if ($2_1 >>> 0 < 3 >>> 0) {
    break block
   }
   HEAP8[($0_1 + 2 | 0) >> 0] = $1_1;
   HEAP8[($0_1 + 1 | 0) >> 0] = $1_1;
   HEAP8[($3_1 + -3 | 0) >> 0] = $1_1;
   HEAP8[($3_1 + -2 | 0) >> 0] = $1_1;
   if ($2_1 >>> 0 < 7 >>> 0) {
    break block
   }
   HEAP8[($0_1 + 3 | 0) >> 0] = $1_1;
   HEAP8[($3_1 + -4 | 0) >> 0] = $1_1;
   if ($2_1 >>> 0 < 9 >>> 0) {
    break block
   }
   $4_1 = (0 - $0_1 | 0) & 3 | 0;
   $3_1 = $0_1 + $4_1 | 0;
   $1_1 = Math_imul($1_1 & 255 | 0, 16843009);
   HEAP32[$3_1 >> 2] = $1_1;
   $4_1 = ($2_1 - $4_1 | 0) & -4 | 0;
   $2_1 = $3_1 + $4_1 | 0;
   HEAP32[($2_1 + -4 | 0) >> 2] = $1_1;
   if ($4_1 >>> 0 < 9 >>> 0) {
    break block
   }
   HEAP32[($3_1 + 8 | 0) >> 2] = $1_1;
   HEAP32[($3_1 + 4 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -8 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -12 | 0) >> 2] = $1_1;
   if ($4_1 >>> 0 < 25 >>> 0) {
    break block
   }
   HEAP32[($3_1 + 24 | 0) >> 2] = $1_1;
   HEAP32[($3_1 + 20 | 0) >> 2] = $1_1;
   HEAP32[($3_1 + 16 | 0) >> 2] = $1_1;
   HEAP32[($3_1 + 12 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -16 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -20 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -24 | 0) >> 2] = $1_1;
   HEAP32[($2_1 + -28 | 0) >> 2] = $1_1;
   $5_1 = $3_1 & 4 | 0 | 24 | 0;
   $2_1 = $4_1 - $5_1 | 0;
   if ($2_1 >>> 0 < 32 >>> 0) {
    break block
   }
   i64toi32_i32$0 = 0;
   i64toi32_i32$1 = 1;
   i64toi32_i32$1 = __wasm_i64_mul($1_1 | 0, i64toi32_i32$0 | 0, 1 | 0, i64toi32_i32$1 | 0) | 0;
   i64toi32_i32$0 = i64toi32_i32$HIGH_BITS;
   $6_1 = i64toi32_i32$1;
   $6$hi = i64toi32_i32$0;
   $1_1 = $3_1 + $5_1 | 0;
   label : while (1) {
    i64toi32_i32$0 = $6$hi;
    i64toi32_i32$1 = $1_1;
    HEAP32[($1_1 + 24 | 0) >> 2] = $6_1;
    HEAP32[($1_1 + 28 | 0) >> 2] = i64toi32_i32$0;
    i64toi32_i32$1 = $1_1;
    HEAP32[($1_1 + 16 | 0) >> 2] = $6_1;
    HEAP32[($1_1 + 20 | 0) >> 2] = i64toi32_i32$0;
    i64toi32_i32$1 = $1_1;
    HEAP32[($1_1 + 8 | 0) >> 2] = $6_1;
    HEAP32[($1_1 + 12 | 0) >> 2] = i64toi32_i32$0;
    i64toi32_i32$1 = $1_1;
    HEAP32[$1_1 >> 2] = $6_1;
    HEAP32[($1_1 + 4 | 0) >> 2] = i64toi32_i32$0;
    $1_1 = $1_1 + 32 | 0;
    $2_1 = $2_1 + -32 | 0;
    if ($2_1 >>> 0 > 31 >>> 0) {
     continue label
    }
    break label;
   };
  }
  return $0_1 | 0;
 }
 
 function $22($0_1, $1_1, $2_1, $3_1, $4_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  $4_1 = $4_1 | 0;
  var $5_1 = 0, i64toi32_i32$0 = 0, $8_1 = 0, $6_1 = 0, $7_1 = 0;
  $5_1 = global$0 - 208 | 0;
  global$0 = $5_1;
  HEAP32[($5_1 + 204 | 0) >> 2] = $2_1;
  wasm2js_memory_fill($5_1 + 160 | 0, 0, 40);
  HEAP32[($5_1 + 200 | 0) >> 2] = HEAP32[($5_1 + 204 | 0) >> 2] | 0;
  block1 : {
   block : {
    if (($23(0 | 0, $1_1 | 0, $5_1 + 200 | 0 | 0, $5_1 + 80 | 0 | 0, $5_1 + 160 | 0 | 0, $3_1 | 0, $4_1 | 0) | 0 | 0) >= (0 | 0)) {
     break block
    }
    $4_1 = -1;
    break block1;
   }
   block3 : {
    block2 : {
     if ((HEAP32[($0_1 + 76 | 0) >> 2] | 0 | 0) >= (0 | 0)) {
      break block2
     }
     $6_1 = 1;
     break block3;
    }
    $6_1 = !($7($0_1 | 0) | 0);
   }
   $7_1 = HEAP32[$0_1 >> 2] | 0;
   HEAP32[$0_1 >> 2] = $7_1 & -33 | 0;
   block7 : {
    block6 : {
     block5 : {
      block4 : {
       if (HEAP32[($0_1 + 48 | 0) >> 2] | 0) {
        break block4
       }
       HEAP32[($0_1 + 48 | 0) >> 2] = 80;
       HEAP32[($0_1 + 28 | 0) >> 2] = 0;
       i64toi32_i32$0 = 0;
       HEAP32[($0_1 + 16 | 0) >> 2] = 0;
       HEAP32[($0_1 + 20 | 0) >> 2] = i64toi32_i32$0;
       $8_1 = HEAP32[($0_1 + 44 | 0) >> 2] | 0;
       HEAP32[($0_1 + 44 | 0) >> 2] = $5_1;
       break block5;
      }
      $8_1 = 0;
      if (HEAP32[($0_1 + 16 | 0) >> 2] | 0) {
       break block6
      }
     }
     $2_1 = -1;
     if ($13($0_1 | 0) | 0) {
      break block7
     }
    }
    $2_1 = $23($0_1 | 0, $1_1 | 0, $5_1 + 200 | 0 | 0, $5_1 + 80 | 0 | 0, $5_1 + 160 | 0 | 0, $3_1 | 0, $4_1 | 0) | 0;
   }
   $4_1 = $7_1 & 32 | 0;
   block8 : {
    if (!$8_1) {
     break block8
    }
    FUNCTION_TABLE[HEAP32[($0_1 + 36 | 0) >> 2] | 0 | 0]($0_1, 0, 0) | 0;
    HEAP32[($0_1 + 48 | 0) >> 2] = 0;
    HEAP32[($0_1 + 44 | 0) >> 2] = $8_1;
    HEAP32[($0_1 + 28 | 0) >> 2] = 0;
    $3_1 = HEAP32[($0_1 + 20 | 0) >> 2] | 0;
    i64toi32_i32$0 = 0;
    HEAP32[($0_1 + 16 | 0) >> 2] = 0;
    HEAP32[($0_1 + 20 | 0) >> 2] = i64toi32_i32$0;
    $2_1 = $3_1 ? $2_1 : -1;
   }
   $3_1 = HEAP32[$0_1 >> 2] | 0;
   HEAP32[$0_1 >> 2] = $3_1 | $4_1 | 0;
   $4_1 = $3_1 & 32 | 0 ? -1 : $2_1;
   if ($6_1) {
    break block1
   }
   $8($0_1 | 0);
  }
  global$0 = $5_1 + 208 | 0;
  return $4_1 | 0;
 }
 
 function $23($0_1, $1_1, $2_1, $3_1, $4_1, $5_1, $6_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  $4_1 = $4_1 | 0;
  $5_1 = $5_1 | 0;
  $6_1 = $6_1 | 0;
  var $13_1 = 0, $7_1 = 0, $16_1 = 0, $21_1 = 0, $18_1 = 0, $15_1 = 0, i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, $14_1 = 0, $12_1 = 0, i64toi32_i32$2 = 0, $17_1 = 0, $20_1 = 0, $23_1 = 0, $19_1 = 0, i64toi32_i32$5 = 0, $26_1 = 0, $26$hi = 0, $10_1 = 0, $25_1 = 0, $11_1 = 0, i64toi32_i32$3 = 0, $22_1 = 0, $24_1 = 0, $34_1 = 0, $35_1 = 0, $36_1 = 0, $8_1 = 0, $9_1 = 0, $270 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  $7_1 = global$0 - 64 | 0;
  global$0 = $7_1;
  HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
  $8_1 = $7_1 + 41 | 0;
  $9_1 = $7_1 + 39 | 0;
  $10_1 = $7_1 + 40 | 0;
  $11_1 = 0;
  $12_1 = 0;
  block68 : {
   block32 : {
    block26 : {
     block : {
      label4 : while (1) {
       $13_1 = 0;
       label1 : while (1) {
        $14_1 = $1_1;
        if (($13_1 | 0) > ($12_1 ^ 2147483647 | 0 | 0)) {
         break block
        }
        $12_1 = $13_1 + $12_1 | 0;
        $13_1 = $1_1;
        block31 : {
         block34 : {
          block47 : {
           block60 : {
            block15 : {
             block1 : {
              $15_1 = HEAPU8[$13_1 >> 0] | 0;
              if (!$15_1) {
               break block1
              }
              label7 : while (1) {
               block4 : {
                block3 : {
                 block2 : {
                  $15_1 = $15_1 & 255 | 0;
                  if ($15_1) {
                   break block2
                  }
                  $1_1 = $13_1;
                  break block3;
                 }
                 if (($15_1 | 0) != (37 | 0)) {
                  break block4
                 }
                 $15_1 = $13_1;
                 label : while (1) {
                  block5 : {
                   if ((HEAPU8[($15_1 + 1 | 0) >> 0] | 0 | 0) == (37 | 0)) {
                    break block5
                   }
                   $1_1 = $15_1;
                   break block3;
                  }
                  $13_1 = $13_1 + 1 | 0;
                  $16_1 = HEAPU8[($15_1 + 2 | 0) >> 0] | 0;
                  $1_1 = $15_1 + 2 | 0;
                  $15_1 = $1_1;
                  if (($16_1 | 0) == (37 | 0)) {
                   continue label
                  }
                  break label;
                 };
                }
                $13_1 = $13_1 - $14_1 | 0;
                $15_1 = $12_1 ^ 2147483647 | 0;
                if (($13_1 | 0) > ($15_1 | 0)) {
                 break block
                }
                block6 : {
                 if (!$0_1) {
                  break block6
                 }
                 $24($0_1 | 0, $14_1 | 0, $13_1 | 0);
                }
                if ($13_1) {
                 continue label1
                }
                HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
                $13_1 = $1_1 + 1 | 0;
                $17_1 = -1;
                block7 : {
                 $16_1 = (HEAP8[($1_1 + 1 | 0) >> 0] | 0) + -48 | 0;
                 if ($16_1 >>> 0 > 9 >>> 0) {
                  break block7
                 }
                 if ((HEAPU8[($1_1 + 2 | 0) >> 0] | 0 | 0) != (36 | 0)) {
                  break block7
                 }
                 $13_1 = $1_1 + 3 | 0;
                 $11_1 = 1;
                 $17_1 = $16_1;
                }
                HEAP32[($7_1 + 60 | 0) >> 2] = $13_1;
                $18_1 = 0;
                block9 : {
                 block8 : {
                  $19_1 = HEAP8[$13_1 >> 0] | 0;
                  $1_1 = $19_1 + -32 | 0;
                  if ($1_1 >>> 0 <= 31 >>> 0) {
                   break block8
                  }
                  $16_1 = $13_1;
                  break block9;
                 }
                 $18_1 = 0;
                 $16_1 = $13_1;
                 $1_1 = 1 << $1_1 | 0;
                 if (!($1_1 & 75913 | 0)) {
                  break block9
                 }
                 label2 : while (1) {
                  $16_1 = $13_1 + 1 | 0;
                  HEAP32[($7_1 + 60 | 0) >> 2] = $16_1;
                  $18_1 = $1_1 | $18_1 | 0;
                  $19_1 = HEAP8[($13_1 + 1 | 0) >> 0] | 0;
                  $1_1 = $19_1 + -32 | 0;
                  if ($1_1 >>> 0 >= 32 >>> 0) {
                   break block9
                  }
                  $13_1 = $16_1;
                  $1_1 = 1 << $1_1 | 0;
                  if ($1_1 & 75913 | 0) {
                   continue label2
                  }
                  break label2;
                 };
                }
                block17 : {
                 block10 : {
                  if (($19_1 | 0) != (42 | 0)) {
                   break block10
                  }
                  block14 : {
                   block11 : {
                    $13_1 = (HEAP8[($16_1 + 1 | 0) >> 0] | 0) + -48 | 0;
                    if ($13_1 >>> 0 > 9 >>> 0) {
                     break block11
                    }
                    if ((HEAPU8[($16_1 + 2 | 0) >> 0] | 0 | 0) != (36 | 0)) {
                     break block11
                    }
                    block13 : {
                     block12 : {
                      if ($0_1) {
                       break block12
                      }
                      HEAP32[($4_1 + ($13_1 << 2 | 0) | 0) >> 2] = 10;
                      $20_1 = 0;
                      break block13;
                     }
                     $20_1 = HEAP32[($3_1 + ($13_1 << 3 | 0) | 0) >> 2] | 0;
                    }
                    $1_1 = $16_1 + 3 | 0;
                    $11_1 = 1;
                    break block14;
                   }
                   if ($11_1) {
                    break block15
                   }
                   $1_1 = $16_1 + 1 | 0;
                   block16 : {
                    if ($0_1) {
                     break block16
                    }
                    HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
                    $11_1 = 0;
                    $20_1 = 0;
                    break block17;
                   }
                   $13_1 = HEAP32[$2_1 >> 2] | 0;
                   HEAP32[$2_1 >> 2] = $13_1 + 4 | 0;
                   $20_1 = HEAP32[$13_1 >> 2] | 0;
                   $11_1 = 0;
                  }
                  HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
                  if (($20_1 | 0) > (-1 | 0)) {
                   break block17
                  }
                  $20_1 = 0 - $20_1 | 0;
                  $18_1 = $18_1 | 8192 | 0;
                  break block17;
                 }
                 $20_1 = $25($7_1 + 60 | 0 | 0) | 0;
                 if (($20_1 | 0) < (0 | 0)) {
                  break block
                 }
                 $1_1 = HEAP32[($7_1 + 60 | 0) >> 2] | 0;
                }
                $13_1 = 0;
                $21_1 = -1;
                block19 : {
                 block18 : {
                  if ((HEAPU8[$1_1 >> 0] | 0 | 0) == (46 | 0)) {
                   break block18
                  }
                  $22_1 = 0;
                  break block19;
                 }
                 block20 : {
                  if ((HEAPU8[($1_1 + 1 | 0) >> 0] | 0 | 0) != (42 | 0)) {
                   break block20
                  }
                  block24 : {
                   block21 : {
                    $16_1 = (HEAP8[($1_1 + 2 | 0) >> 0] | 0) + -48 | 0;
                    if ($16_1 >>> 0 > 9 >>> 0) {
                     break block21
                    }
                    if ((HEAPU8[($1_1 + 3 | 0) >> 0] | 0 | 0) != (36 | 0)) {
                     break block21
                    }
                    block23 : {
                     block22 : {
                      if ($0_1) {
                       break block22
                      }
                      HEAP32[($4_1 + ($16_1 << 2 | 0) | 0) >> 2] = 10;
                      $21_1 = 0;
                      break block23;
                     }
                     $21_1 = HEAP32[($3_1 + ($16_1 << 3 | 0) | 0) >> 2] | 0;
                    }
                    $1_1 = $1_1 + 4 | 0;
                    break block24;
                   }
                   if ($11_1) {
                    break block15
                   }
                   $1_1 = $1_1 + 2 | 0;
                   block25 : {
                    if ($0_1) {
                     break block25
                    }
                    $21_1 = 0;
                    break block24;
                   }
                   $16_1 = HEAP32[$2_1 >> 2] | 0;
                   HEAP32[$2_1 >> 2] = $16_1 + 4 | 0;
                   $21_1 = HEAP32[$16_1 >> 2] | 0;
                  }
                  HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
                  $22_1 = ($21_1 | 0) > (-1 | 0);
                  break block19;
                 }
                 HEAP32[($7_1 + 60 | 0) >> 2] = $1_1 + 1 | 0;
                 $22_1 = 1;
                 $21_1 = $25($7_1 + 60 | 0 | 0) | 0;
                 $1_1 = HEAP32[($7_1 + 60 | 0) >> 2] | 0;
                }
                label3 : while (1) {
                 $16_1 = $13_1;
                 $23_1 = 28;
                 $19_1 = $1_1;
                 $13_1 = HEAP8[$1_1 >> 0] | 0;
                 if (($13_1 + -123 | 0) >>> 0 < -58 >>> 0) {
                  break block26
                 }
                 $1_1 = $1_1 + 1 | 0;
                 $13_1 = HEAPU8[((Math_imul($16_1, 58) + $13_1 | 0) + 65599 | 0) >> 0] | 0;
                 if ((($13_1 + -1 | 0) & 255 | 0) >>> 0 < 8 >>> 0) {
                  continue label3
                 }
                 break label3;
                };
                HEAP32[($7_1 + 60 | 0) >> 2] = $1_1;
                block30 : {
                 block27 : {
                  if (($13_1 | 0) == (27 | 0)) {
                   break block27
                  }
                  if (!$13_1) {
                   break block26
                  }
                  block28 : {
                   if (($17_1 | 0) < (0 | 0)) {
                    break block28
                   }
                   block29 : {
                    if ($0_1) {
                     break block29
                    }
                    HEAP32[($4_1 + ($17_1 << 2 | 0) | 0) >> 2] = $13_1;
                    continue label4;
                   }
                   i64toi32_i32$2 = $3_1 + ($17_1 << 3 | 0) | 0;
                   i64toi32_i32$0 = HEAP32[i64toi32_i32$2 >> 2] | 0;
                   i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 4 | 0) >> 2] | 0;
                   $270 = i64toi32_i32$0;
                   i64toi32_i32$0 = $7_1;
                   HEAP32[($7_1 + 48 | 0) >> 2] = $270;
                   HEAP32[($7_1 + 52 | 0) >> 2] = i64toi32_i32$1;
                   break block30;
                  }
                  if (!$0_1) {
                   break block31
                  }
                  $26($7_1 + 48 | 0 | 0, $13_1 | 0, $2_1 | 0, $6_1 | 0);
                  break block30;
                 }
                 if (($17_1 | 0) > (-1 | 0)) {
                  break block26
                 }
                 $13_1 = 0;
                 if (!$0_1) {
                  continue label1
                 }
                }
                if ((HEAPU8[$0_1 >> 0] | 0) & 32 | 0) {
                 break block32
                }
                $24_1 = $18_1 & -65537 | 0;
                $18_1 = $18_1 & 8192 | 0 ? $24_1 : $18_1;
                $17_1 = 0;
                $25_1 = 65536;
                $23_1 = $10_1;
                block35 : {
                 block65 : {
                  block64 : {
                   block62 : {
                    block46 : {
                     block44 : {
                      block41 : {
                       block36 : {
                        block56 : {
                         block48 : {
                          block37 : {
                           block39 : {
                            block33 : {
                             block40 : {
                              block38 : {
                               block42 : {
                                block43 : {
                                 $19_1 = HEAPU8[$19_1 >> 0] | 0;
                                 $13_1 = $19_1 << 24 >> 24;
                                 $13_1 = $16_1 ? (($19_1 & 15 | 0 | 0) == (3 | 0) ? $13_1 & -45 | 0 : $13_1) : $13_1;
                                 switch ($13_1 + -88 | 0 | 0) {
                                 case 0:
                                 case 32:
                                  break block33;
                                 case 1:
                                 case 2:
                                 case 3:
                                 case 4:
                                 case 5:
                                 case 6:
                                 case 7:
                                 case 8:
                                 case 10:
                                 case 16:
                                 case 18:
                                 case 19:
                                 case 20:
                                 case 21:
                                 case 25:
                                 case 26:
                                 case 28:
                                 case 30:
                                 case 31:
                                  break block34;
                                 case 9:
                                 case 13:
                                 case 14:
                                 case 15:
                                  break block35;
                                 case 11:
                                  break block36;
                                 case 12:
                                 case 17:
                                  break block37;
                                 case 22:
                                  break block38;
                                 case 23:
                                  break block39;
                                 case 24:
                                  break block40;
                                 case 27:
                                  break block41;
                                 case 29:
                                  break block42;
                                 default:
                                  break block43;
                                 };
                                }
                                $23_1 = $10_1;
                                block45 : {
                                 switch ($13_1 + -65 | 0 | 0) {
                                 case 1:
                                 case 3:
                                  break block34;
                                 case 0:
                                 case 4:
                                 case 5:
                                 case 6:
                                  break block35;
                                 case 2:
                                  break block44;
                                 default:
                                  break block45;
                                 };
                                }
                                if (($13_1 | 0) == (83 | 0)) {
                                 break block46
                                }
                                break block47;
                               }
                               $17_1 = 0;
                               $25_1 = 65536;
                               i64toi32_i32$2 = $7_1;
                               i64toi32_i32$1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                               i64toi32_i32$0 = HEAP32[($7_1 + 52 | 0) >> 2] | 0;
                               $26_1 = i64toi32_i32$1;
                               $26$hi = i64toi32_i32$0;
                               break block48;
                              }
                              $13_1 = 0;
                              block55 : {
                               switch ($16_1 | 0) {
                               case 0:
                                HEAP32[(HEAP32[($7_1 + 48 | 0) >> 2] | 0) >> 2] = $12_1;
                                continue label1;
                               case 1:
                                HEAP32[(HEAP32[($7_1 + 48 | 0) >> 2] | 0) >> 2] = $12_1;
                                continue label1;
                               case 2:
                                i64toi32_i32$1 = $12_1;
                                i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
                                i64toi32_i32$1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                                HEAP32[i64toi32_i32$1 >> 2] = $12_1;
                                HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
                                continue label1;
                               case 3:
                                HEAP16[(HEAP32[($7_1 + 48 | 0) >> 2] | 0) >> 1] = $12_1;
                                continue label1;
                               case 4:
                                HEAP8[(HEAP32[($7_1 + 48 | 0) >> 2] | 0) >> 0] = $12_1;
                                continue label1;
                               case 6:
                                HEAP32[(HEAP32[($7_1 + 48 | 0) >> 2] | 0) >> 2] = $12_1;
                                continue label1;
                               case 7:
                                break block55;
                               default:
                                continue label1;
                               };
                              }
                              i64toi32_i32$1 = $12_1;
                              i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
                              i64toi32_i32$1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                              HEAP32[i64toi32_i32$1 >> 2] = $12_1;
                              HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
                              continue label1;
                             }
                             $21_1 = $21_1 >>> 0 > 8 >>> 0 ? $21_1 : 8;
                             $18_1 = $18_1 | 8 | 0;
                             $13_1 = 120;
                            }
                            $17_1 = 0;
                            $25_1 = 65536;
                            i64toi32_i32$2 = $7_1;
                            i64toi32_i32$0 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                            i64toi32_i32$1 = HEAP32[($7_1 + 52 | 0) >> 2] | 0;
                            $26_1 = i64toi32_i32$0;
                            $26$hi = i64toi32_i32$1;
                            $14_1 = $27(i64toi32_i32$0 | 0, i64toi32_i32$1 | 0, $10_1 | 0, $13_1 & 32 | 0 | 0) | 0;
                            if (!(i64toi32_i32$0 | i64toi32_i32$1 | 0)) {
                             break block56
                            }
                            if (!($18_1 & 8 | 0)) {
                             break block56
                            }
                            $25_1 = ($13_1 >>> 4 | 0) + 65536 | 0;
                            $17_1 = 2;
                            break block56;
                           }
                           $17_1 = 0;
                           $25_1 = 65536;
                           i64toi32_i32$2 = $7_1;
                           i64toi32_i32$1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                           i64toi32_i32$0 = HEAP32[($7_1 + 52 | 0) >> 2] | 0;
                           $26_1 = i64toi32_i32$1;
                           $26$hi = i64toi32_i32$0;
                           $14_1 = $28(i64toi32_i32$1 | 0, i64toi32_i32$0 | 0, $10_1 | 0) | 0;
                           if (!($18_1 & 8 | 0)) {
                            break block56
                           }
                           $13_1 = $8_1 - $14_1 | 0;
                           $21_1 = ($21_1 | 0) > ($13_1 | 0) ? $21_1 : $13_1;
                           break block56;
                          }
                          block57 : {
                           i64toi32_i32$2 = $7_1;
                           i64toi32_i32$0 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                           i64toi32_i32$1 = HEAP32[($7_1 + 52 | 0) >> 2] | 0;
                           $26_1 = i64toi32_i32$0;
                           $26$hi = i64toi32_i32$1;
                           i64toi32_i32$2 = i64toi32_i32$0;
                           i64toi32_i32$0 = -1;
                           i64toi32_i32$3 = -1;
                           if ((i64toi32_i32$1 | 0) > (i64toi32_i32$0 | 0)) {
                            $34_1 = 1
                           } else {
                            if ((i64toi32_i32$1 | 0) >= (i64toi32_i32$0 | 0)) {
                             if (i64toi32_i32$2 >>> 0 <= i64toi32_i32$3 >>> 0) {
                              $35_1 = 0
                             } else {
                              $35_1 = 1
                             }
                             $36_1 = $35_1;
                            } else {
                             $36_1 = 0
                            }
                            $34_1 = $36_1;
                           }
                           if ($34_1) {
                            break block57
                           }
                           i64toi32_i32$2 = $26$hi;
                           i64toi32_i32$2 = 0;
                           i64toi32_i32$3 = 0;
                           i64toi32_i32$1 = $26$hi;
                           i64toi32_i32$0 = $26_1;
                           i64toi32_i32$5 = (i64toi32_i32$3 >>> 0 < i64toi32_i32$0 >>> 0) + i64toi32_i32$1 | 0;
                           i64toi32_i32$5 = i64toi32_i32$2 - i64toi32_i32$5 | 0;
                           $26_1 = i64toi32_i32$3 - i64toi32_i32$0 | 0;
                           $26$hi = i64toi32_i32$5;
                           i64toi32_i32$3 = $7_1;
                           HEAP32[($7_1 + 48 | 0) >> 2] = $26_1;
                           HEAP32[($7_1 + 52 | 0) >> 2] = i64toi32_i32$5;
                           $17_1 = 1;
                           $25_1 = 65536;
                           break block48;
                          }
                          block58 : {
                           if (!($18_1 & 2048 | 0)) {
                            break block58
                           }
                           $17_1 = 1;
                           $25_1 = 65537;
                           break block48;
                          }
                          $17_1 = $18_1 & 1 | 0;
                          $25_1 = $17_1 ? 65538 : 65536;
                         }
                         i64toi32_i32$5 = $26$hi;
                         $14_1 = $29($26_1 | 0, i64toi32_i32$5 | 0, $10_1 | 0) | 0;
                        }
                        if ($22_1 & ($21_1 | 0) < (0 | 0) | 0) {
                         break block
                        }
                        $18_1 = $22_1 ? $18_1 & -65537 | 0 : $18_1;
                        block59 : {
                         i64toi32_i32$5 = $26$hi;
                         i64toi32_i32$2 = $26_1;
                         i64toi32_i32$3 = 0;
                         i64toi32_i32$0 = 0;
                         if ((i64toi32_i32$2 | 0) != (i64toi32_i32$0 | 0) | (i64toi32_i32$5 | 0) != (i64toi32_i32$3 | 0) | 0) {
                          break block59
                         }
                         if ($21_1) {
                          break block59
                         }
                         $14_1 = $10_1;
                         $23_1 = $14_1;
                         $21_1 = 0;
                         break block34;
                        }
                        i64toi32_i32$2 = $26$hi;
                        $13_1 = ($10_1 - $14_1 | 0) + !($26_1 | i64toi32_i32$2 | 0) | 0;
                        $21_1 = ($21_1 | 0) > ($13_1 | 0) ? $21_1 : $13_1;
                        break block47;
                       }
                       $13_1 = HEAPU8[($7_1 + 48 | 0) >> 0] | 0;
                       break block60;
                      }
                      $13_1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                      $14_1 = $13_1 ? $13_1 : 65597;
                      $13_1 = $15($14_1 | 0, ($21_1 >>> 0 < 2147483647 >>> 0 ? $21_1 : 2147483647) | 0) | 0;
                      $23_1 = $14_1 + $13_1 | 0;
                      block61 : {
                       if (($21_1 | 0) <= (-1 | 0)) {
                        break block61
                       }
                       $18_1 = $24_1;
                       $21_1 = $13_1;
                       break block34;
                      }
                      $18_1 = $24_1;
                      $21_1 = $13_1;
                      if (HEAPU8[$23_1 >> 0] | 0) {
                       break block
                      }
                      break block34;
                     }
                     i64toi32_i32$0 = $7_1;
                     i64toi32_i32$2 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                     i64toi32_i32$5 = HEAP32[($7_1 + 52 | 0) >> 2] | 0;
                     $26_1 = i64toi32_i32$2;
                     $26$hi = i64toi32_i32$5;
                     if (!!(i64toi32_i32$2 | i64toi32_i32$5 | 0)) {
                      break block62
                     }
                     $13_1 = 0;
                     break block60;
                    }
                    block63 : {
                     if (!$21_1) {
                      break block63
                     }
                     $15_1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                     break block64;
                    }
                    $13_1 = 0;
                    $30($0_1 | 0, 32 | 0, $20_1 | 0, 0 | 0, $18_1 | 0);
                    break block65;
                   }
                   HEAP32[($7_1 + 12 | 0) >> 2] = 0;
                   i64toi32_i32$5 = $26$hi;
                   HEAP32[($7_1 + 8 | 0) >> 2] = $26_1;
                   HEAP32[($7_1 + 48 | 0) >> 2] = $7_1 + 8 | 0;
                   $15_1 = $7_1 + 8 | 0;
                   $21_1 = -1;
                  }
                  $13_1 = 0;
                  block66 : {
                   label5 : while (1) {
                    $16_1 = HEAP32[$15_1 >> 2] | 0;
                    if (!$16_1) {
                     break block66
                    }
                    $16_1 = $41($7_1 + 4 | 0 | 0, $16_1 | 0) | 0;
                    if (($16_1 | 0) < (0 | 0)) {
                     break block32
                    }
                    if ($16_1 >>> 0 > ($21_1 - $13_1 | 0) >>> 0) {
                     break block66
                    }
                    $15_1 = $15_1 + 4 | 0;
                    $13_1 = $16_1 + $13_1 | 0;
                    if ($13_1 >>> 0 < $21_1 >>> 0) {
                     continue label5
                    }
                    break label5;
                   };
                  }
                  $23_1 = 61;
                  if (($13_1 | 0) < (0 | 0)) {
                   break block26
                  }
                  $30($0_1 | 0, 32 | 0, $20_1 | 0, $13_1 | 0, $18_1 | 0);
                  block67 : {
                   if ($13_1) {
                    break block67
                   }
                   $13_1 = 0;
                   break block65;
                  }
                  $16_1 = 0;
                  $15_1 = HEAP32[($7_1 + 48 | 0) >> 2] | 0;
                  label6 : while (1) {
                   $14_1 = HEAP32[$15_1 >> 2] | 0;
                   if (!$14_1) {
                    break block65
                   }
                   $14_1 = $41($7_1 + 4 | 0 | 0, $14_1 | 0) | 0;
                   $16_1 = $14_1 + $16_1 | 0;
                   if ($16_1 >>> 0 > $13_1 >>> 0) {
                    break block65
                   }
                   $24($0_1 | 0, $7_1 + 4 | 0 | 0, $14_1 | 0);
                   $15_1 = $15_1 + 4 | 0;
                   if ($16_1 >>> 0 < $13_1 >>> 0) {
                    continue label6
                   }
                   break label6;
                  };
                 }
                 $30($0_1 | 0, 32 | 0, $20_1 | 0, $13_1 | 0, $18_1 ^ 8192 | 0 | 0);
                 $13_1 = ($20_1 | 0) > ($13_1 | 0) ? $20_1 : $13_1;
                 continue label1;
                }
                if ($22_1 & ($21_1 | 0) < (0 | 0) | 0) {
                 break block
                }
                $23_1 = 61;
                $13_1 = FUNCTION_TABLE[$5_1 | 0]($0_1, +HEAPF64[($7_1 + 48 | 0) >> 3], $20_1, $21_1, $18_1, $13_1) | 0;
                if (($13_1 | 0) >= (0 | 0)) {
                 continue label1
                }
                break block26;
               }
               $15_1 = HEAPU8[($13_1 + 1 | 0) >> 0] | 0;
               $13_1 = $13_1 + 1 | 0;
               continue label7;
              };
             }
             if ($0_1) {
              break block68
             }
             if (!$11_1) {
              break block31
             }
             $13_1 = 1;
             block69 : {
              label8 : while (1) {
               $15_1 = HEAP32[($4_1 + ($13_1 << 2 | 0) | 0) >> 2] | 0;
               if (!$15_1) {
                break block69
               }
               $26($3_1 + ($13_1 << 3 | 0) | 0 | 0, $15_1 | 0, $2_1 | 0, $6_1 | 0);
               $12_1 = 1;
               $13_1 = $13_1 + 1 | 0;
               if (($13_1 | 0) != (10 | 0)) {
                continue label8
               }
               break block68;
              };
             }
             block70 : {
              if ($13_1 >>> 0 < 10 >>> 0) {
               break block70
              }
              $12_1 = 1;
              break block68;
             }
             label9 : while (1) {
              if (HEAP32[($4_1 + ($13_1 << 2 | 0) | 0) >> 2] | 0) {
               break block15
              }
              $12_1 = 1;
              $13_1 = $13_1 + 1 | 0;
              if (($13_1 | 0) == (10 | 0)) {
               break block68
              }
              continue label9;
             };
            }
            $23_1 = 28;
            break block26;
           }
           HEAP8[($7_1 + 39 | 0) >> 0] = $13_1;
           $21_1 = 1;
           $14_1 = $9_1;
           $23_1 = $10_1;
           $18_1 = $24_1;
           break block34;
          }
          $23_1 = $10_1;
         }
         $1_1 = $23_1 - $14_1 | 0;
         $19_1 = ($21_1 | 0) > ($1_1 | 0) ? $21_1 : $1_1;
         if (($19_1 | 0) > ($17_1 ^ 2147483647 | 0 | 0)) {
          break block
         }
         $23_1 = 61;
         $16_1 = $17_1 + $19_1 | 0;
         $13_1 = ($20_1 | 0) > ($16_1 | 0) ? $20_1 : $16_1;
         if ($13_1 >>> 0 > $15_1 >>> 0) {
          break block26
         }
         $30($0_1 | 0, 32 | 0, $13_1 | 0, $16_1 | 0, $18_1 | 0);
         $24($0_1 | 0, $25_1 | 0, $17_1 | 0);
         $30($0_1 | 0, 48 | 0, $13_1 | 0, $16_1 | 0, $18_1 ^ 65536 | 0 | 0);
         $30($0_1 | 0, 48 | 0, $19_1 | 0, $1_1 | 0, 0 | 0);
         $24($0_1 | 0, $14_1 | 0, $1_1 | 0);
         $30($0_1 | 0, 32 | 0, $13_1 | 0, $16_1 | 0, $18_1 ^ 8192 | 0 | 0);
         $1_1 = HEAP32[($7_1 + 60 | 0) >> 2] | 0;
         continue label1;
        }
        break label1;
       };
       break label4;
      };
      $12_1 = 0;
      break block68;
     }
     $23_1 = 61;
    }
    (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = $23_1), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
   }
   $12_1 = -1;
  }
  global$0 = $7_1 + 64 | 0;
  return $12_1 | 0;
 }
 
 function $24($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  block : {
   if ((HEAPU8[$0_1 >> 0] | 0) & 32 | 0) {
    break block
   }
   $20($1_1 | 0, $2_1 | 0, $0_1 | 0) | 0;
  }
 }
 
 function $25($0_1) {
  $0_1 = $0_1 | 0;
  var $3_1 = 0, $1_1 = 0, $2_1 = 0, $4_1 = 0, $5_1 = 0;
  $1_1 = 0;
  block : {
   $2_1 = HEAP32[$0_1 >> 2] | 0;
   $3_1 = (HEAP8[$2_1 >> 0] | 0) + -48 | 0;
   if ($3_1 >>> 0 <= 9 >>> 0) {
    break block
   }
   return 0 | 0;
  }
  label : while (1) {
   $4_1 = -1;
   block1 : {
    if ($1_1 >>> 0 > 214748364 >>> 0) {
     break block1
    }
    $1_1 = Math_imul($1_1, 10);
    $4_1 = $3_1 >>> 0 > ($1_1 ^ 2147483647 | 0) >>> 0 ? -1 : $3_1 + $1_1 | 0;
   }
   $3_1 = $2_1 + 1 | 0;
   HEAP32[$0_1 >> 2] = $3_1;
   $5_1 = HEAP8[($2_1 + 1 | 0) >> 0] | 0;
   $1_1 = $4_1;
   $2_1 = $3_1;
   $3_1 = $5_1 + -48 | 0;
   if ($3_1 >>> 0 < 10 >>> 0) {
    continue label
   }
   break label;
  };
  return $1_1 | 0;
 }
 
 function $26($0_1, $1_1, $2_1, $3_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, $21_1 = 0, $29_1 = 0, $37_1 = 0, $45_1 = 0, $55_1 = 0, $63_1 = 0, $71 = 0, $79 = 0, $87 = 0, $97 = 0, $105 = 0, $115 = 0, $125 = 0, $133 = 0, $141 = 0;
  block18 : {
   switch ($1_1 + -9 | 0 | 0) {
   case 0:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    HEAP32[$0_1 >> 2] = HEAP32[$1_1 >> 2] | 0;
    return;
   case 1:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = i64toi32_i32$0 >> 31 | 0;
    $21_1 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $21_1;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 2:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$1 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$0 = 0;
    $29_1 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $29_1;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 4:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = i64toi32_i32$0 >> 31 | 0;
    $37_1 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $37_1;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 5:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$1 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$0 = 0;
    $45_1 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $45_1;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 3:
    $1_1 = ((HEAP32[$2_1 >> 2] | 0) + 7 | 0) & -8 | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 8 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = HEAP32[($1_1 + 4 | 0) >> 2] | 0;
    $55_1 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $55_1;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 6:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$1 = HEAP16[$1_1 >> 1] | 0;
    i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
    $63_1 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $63_1;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 7:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAPU16[$1_1 >> 1] | 0;
    i64toi32_i32$1 = 0;
    $71 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $71;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 8:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$1 = HEAP8[$1_1 >> 0] | 0;
    i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
    $79 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $79;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 9:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAPU8[$1_1 >> 0] | 0;
    i64toi32_i32$1 = 0;
    $87 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $87;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 10:
    $1_1 = ((HEAP32[$2_1 >> 2] | 0) + 7 | 0) & -8 | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 8 | 0;
    i64toi32_i32$1 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$0 = HEAP32[($1_1 + 4 | 0) >> 2] | 0;
    $97 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $97;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 11:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = 0;
    $105 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $105;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 12:
    $1_1 = ((HEAP32[$2_1 >> 2] | 0) + 7 | 0) & -8 | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 8 | 0;
    i64toi32_i32$1 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$0 = HEAP32[($1_1 + 4 | 0) >> 2] | 0;
    $115 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $115;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 13:
    $1_1 = ((HEAP32[$2_1 >> 2] | 0) + 7 | 0) & -8 | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 8 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = HEAP32[($1_1 + 4 | 0) >> 2] | 0;
    $125 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $125;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 14:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$1 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
    $133 = i64toi32_i32$1;
    i64toi32_i32$1 = $0_1;
    HEAP32[i64toi32_i32$1 >> 2] = $133;
    HEAP32[(i64toi32_i32$1 + 4 | 0) >> 2] = i64toi32_i32$0;
    return;
   case 15:
    $1_1 = HEAP32[$2_1 >> 2] | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 4 | 0;
    i64toi32_i32$0 = HEAP32[$1_1 >> 2] | 0;
    i64toi32_i32$1 = 0;
    $141 = i64toi32_i32$0;
    i64toi32_i32$0 = $0_1;
    HEAP32[i64toi32_i32$0 >> 2] = $141;
    HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$1;
    return;
   case 16:
    $1_1 = ((HEAP32[$2_1 >> 2] | 0) + 7 | 0) & -8 | 0;
    HEAP32[$2_1 >> 2] = $1_1 + 8 | 0;
    HEAPF64[$0_1 >> 3] = +HEAPF64[$1_1 >> 3];
    return;
   case 17:
    FUNCTION_TABLE[$3_1 | 0]($0_1, $2_1);
    break;
   default:
    break block18;
   };
  }
 }
 
 function $27($0_1, $0$hi, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $0$hi = $0$hi | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$4 = 0, i64toi32_i32$2 = 0, i64toi32_i32$3 = 0, $3_1 = 0, $11_1 = 0, $3$hi = 0;
  block : {
   i64toi32_i32$0 = $0$hi;
   if (!($0_1 | i64toi32_i32$0 | 0)) {
    break block
   }
   label : while (1) {
    $1_1 = $1_1 + -1 | 0;
    i64toi32_i32$0 = $0$hi;
    $3_1 = $0_1;
    $3$hi = i64toi32_i32$0;
    HEAP8[$1_1 >> 0] = HEAPU8[(($3_1 & 15 | 0) + 66128 | 0) >> 0] | 0 | $2_1 | 0;
    i64toi32_i32$2 = $3_1;
    i64toi32_i32$1 = 0;
    i64toi32_i32$3 = 4;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = 0;
     $11_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
     $11_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
    }
    $0_1 = $11_1;
    $0$hi = i64toi32_i32$1;
    i64toi32_i32$1 = $3$hi;
    i64toi32_i32$0 = $3_1;
    i64toi32_i32$2 = 0;
    i64toi32_i32$3 = 15;
    if (i64toi32_i32$1 >>> 0 > i64toi32_i32$2 >>> 0 | ((i64toi32_i32$1 | 0) == (i64toi32_i32$2 | 0) & i64toi32_i32$0 >>> 0 > i64toi32_i32$3 >>> 0 | 0) | 0) {
     continue label
    }
    break label;
   };
  }
  return $1_1 | 0;
 }
 
 function $28($0_1, $0$hi, $1_1) {
  $0_1 = $0_1 | 0;
  $0$hi = $0$hi | 0;
  $1_1 = $1_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$4 = 0, i64toi32_i32$2 = 0, i64toi32_i32$3 = 0, $2_1 = 0, $10_1 = 0, $2$hi = 0;
  block : {
   i64toi32_i32$0 = $0$hi;
   if (!($0_1 | i64toi32_i32$0 | 0)) {
    break block
   }
   label : while (1) {
    $1_1 = $1_1 + -1 | 0;
    i64toi32_i32$0 = $0$hi;
    $2_1 = $0_1;
    $2$hi = i64toi32_i32$0;
    HEAP8[$1_1 >> 0] = $2_1 & 7 | 0 | 48 | 0;
    i64toi32_i32$2 = $2_1;
    i64toi32_i32$1 = 0;
    i64toi32_i32$3 = 3;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = 0;
     $10_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
     $10_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
    }
    $0_1 = $10_1;
    $0$hi = i64toi32_i32$1;
    i64toi32_i32$1 = $2$hi;
    i64toi32_i32$0 = $2_1;
    i64toi32_i32$2 = 0;
    i64toi32_i32$3 = 7;
    if (i64toi32_i32$1 >>> 0 > i64toi32_i32$2 >>> 0 | ((i64toi32_i32$1 | 0) == (i64toi32_i32$2 | 0) & i64toi32_i32$0 >>> 0 > i64toi32_i32$3 >>> 0 | 0) | 0) {
     continue label
    }
    break label;
   };
  }
  return $1_1 | 0;
 }
 
 function $29($0_1, $0$hi, $1_1) {
  $0_1 = $0_1 | 0;
  $0$hi = $0$hi | 0;
  $1_1 = $1_1 | 0;
  var i64toi32_i32$2 = 0, i64toi32_i32$0 = 0, i64toi32_i32$3 = 0, i64toi32_i32$1 = 0, i64toi32_i32$5 = 0, $3_1 = 0, $4_1 = 0, $2_1 = 0, $2$hi = 0, $15_1 = 0, $15$hi = 0;
  block : {
   i64toi32_i32$0 = $0$hi;
   i64toi32_i32$2 = $0_1;
   i64toi32_i32$1 = 1;
   i64toi32_i32$3 = 0;
   if (i64toi32_i32$0 >>> 0 < i64toi32_i32$1 >>> 0 | ((i64toi32_i32$0 | 0) == (i64toi32_i32$1 | 0) & i64toi32_i32$2 >>> 0 < i64toi32_i32$3 >>> 0 | 0) | 0) {
    break block
   }
   label : while (1) {
    $1_1 = $1_1 + -1 | 0;
    i64toi32_i32$2 = $0$hi;
    $2_1 = $0_1;
    $2$hi = i64toi32_i32$2;
    i64toi32_i32$0 = 0;
    i64toi32_i32$0 = __wasm_i64_udiv($0_1 | 0, i64toi32_i32$2 | 0, 10 | 0, i64toi32_i32$0 | 0) | 0;
    i64toi32_i32$2 = i64toi32_i32$HIGH_BITS;
    $0_1 = i64toi32_i32$0;
    $0$hi = i64toi32_i32$2;
    i64toi32_i32$0 = 0;
    i64toi32_i32$0 = __wasm_i64_mul($0_1 | 0, i64toi32_i32$2 | 0, 10 | 0, i64toi32_i32$0 | 0) | 0;
    i64toi32_i32$2 = i64toi32_i32$HIGH_BITS;
    $15_1 = i64toi32_i32$0;
    $15$hi = i64toi32_i32$2;
    i64toi32_i32$2 = $2$hi;
    i64toi32_i32$3 = $2_1;
    i64toi32_i32$0 = $15$hi;
    i64toi32_i32$1 = $15_1;
    i64toi32_i32$5 = (i64toi32_i32$3 >>> 0 < i64toi32_i32$1 >>> 0) + i64toi32_i32$0 | 0;
    i64toi32_i32$5 = i64toi32_i32$2 - i64toi32_i32$5 | 0;
    HEAP8[$1_1 >> 0] = i64toi32_i32$3 - i64toi32_i32$1 | 0 | 48 | 0;
    i64toi32_i32$5 = i64toi32_i32$2;
    i64toi32_i32$5 = i64toi32_i32$2;
    i64toi32_i32$2 = i64toi32_i32$3;
    i64toi32_i32$3 = 9;
    i64toi32_i32$1 = -1;
    if (i64toi32_i32$5 >>> 0 > i64toi32_i32$3 >>> 0 | ((i64toi32_i32$5 | 0) == (i64toi32_i32$3 | 0) & i64toi32_i32$2 >>> 0 > i64toi32_i32$1 >>> 0 | 0) | 0) {
     continue label
    }
    break label;
   };
  }
  block1 : {
   i64toi32_i32$2 = $0$hi;
   if (!($0_1 | i64toi32_i32$2 | 0)) {
    break block1
   }
   $3_1 = $0_1;
   label1 : while (1) {
    $1_1 = $1_1 + -1 | 0;
    $4_1 = $3_1;
    $3_1 = ($4_1 >>> 0) / (10 >>> 0) | 0;
    HEAP8[$1_1 >> 0] = $4_1 - Math_imul($3_1, 10) | 0 | 48 | 0;
    if ($4_1 >>> 0 > 9 >>> 0) {
     continue label1
    }
    break label1;
   };
  }
  return $1_1 | 0;
 }
 
 function $30($0_1, $1_1, $2_1, $3_1, $4_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  $4_1 = $4_1 | 0;
  var $5_1 = 0;
  $5_1 = global$0 - 256 | 0;
  global$0 = $5_1;
  block : {
   if (($2_1 | 0) <= ($3_1 | 0)) {
    break block
   }
   if ($4_1 & 73728 | 0) {
    break block
   }
   $3_1 = $2_1 - $3_1 | 0;
   $2_1 = $3_1 >>> 0 < 256 >>> 0;
   $21($5_1 | 0, $1_1 | 0, ($2_1 ? $3_1 : 256) | 0) | 0;
   block1 : {
    if ($2_1) {
     break block1
    }
    label : while (1) {
     $24($0_1 | 0, $5_1 | 0, 256 | 0);
     $3_1 = $3_1 + -256 | 0;
     if ($3_1 >>> 0 > 255 >>> 0) {
      continue label
     }
     break label;
    };
   }
   $24($0_1 | 0, $5_1 | 0, $3_1 | 0);
  }
  global$0 = $5_1 + 256 | 0;
 }
 
 function $31($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  return $22($0_1 | 0, $1_1 | 0, $2_1 | 0, 4 | 0, 5 | 0) | 0 | 0;
 }
 
 function $32($0_1, $1_1, $2_1, $3_1, $4_1, $5_1) {
  $0_1 = $0_1 | 0;
  $1_1 = +$1_1;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  $4_1 = $4_1 | 0;
  $5_1 = $5_1 | 0;
  var $10_1 = 0, $11_1 = 0, $18_1 = 0, $19_1 = 0, $12_1 = 0, $15_1 = 0, $6_1 = 0, i64toi32_i32$1 = 0, i64toi32_i32$2 = 0, i64toi32_i32$4 = 0, i64toi32_i32$5 = 0, $22_1 = 0, i64toi32_i32$3 = 0, i64toi32_i32$0 = 0, $23_1 = 0, $20_1 = 0, $17_1 = 0, $8_1 = 0, $27_1 = 0.0, $13_1 = 0, $24_1 = 0, $24$hi = 0, $14_1 = 0, $16_1 = 0, $9_1 = 0, $21_1 = 0, $7_1 = 0, $46_1 = 0, $47_1 = 0, $48_1 = 0, $142 = 0, $25$hi = 0, $49_1 = 0, $897 = 0, $133 = 0, $25_1 = 0, $172 = 0, $174$hi = 0, $176$hi = 0, $26$hi = 0, $183 = 0, $183$hi = 0, $389 = 0.0, $890 = 0;
  $6_1 = global$0 - 560 | 0;
  global$0 = $6_1;
  $7_1 = 0;
  HEAP32[($6_1 + 44 | 0) >> 2] = 0;
  block1 : {
   block : {
    i64toi32_i32$0 = $34(+$1_1) | 0;
    i64toi32_i32$1 = i64toi32_i32$HIGH_BITS;
    $24_1 = i64toi32_i32$0;
    $24$hi = i64toi32_i32$1;
    i64toi32_i32$2 = i64toi32_i32$0;
    i64toi32_i32$0 = -1;
    i64toi32_i32$3 = -1;
    if ((i64toi32_i32$1 | 0) > (i64toi32_i32$0 | 0)) {
     $46_1 = 1
    } else {
     if ((i64toi32_i32$1 | 0) >= (i64toi32_i32$0 | 0)) {
      if (i64toi32_i32$2 >>> 0 <= i64toi32_i32$3 >>> 0) {
       $47_1 = 0
      } else {
       $47_1 = 1
      }
      $48_1 = $47_1;
     } else {
      $48_1 = 0
     }
     $46_1 = $48_1;
    }
    if ($46_1) {
     break block
    }
    $8_1 = 1;
    $9_1 = 65546;
    $1_1 = -$1_1;
    i64toi32_i32$2 = $34(+$1_1) | 0;
    i64toi32_i32$1 = i64toi32_i32$HIGH_BITS;
    $24_1 = i64toi32_i32$2;
    $24$hi = i64toi32_i32$1;
    break block1;
   }
   block2 : {
    if (!($4_1 & 2048 | 0)) {
     break block2
    }
    $8_1 = 1;
    $9_1 = 65549;
    break block1;
   }
   $8_1 = $4_1 & 1 | 0;
   $9_1 = $8_1 ? 65552 : 65547;
   $7_1 = !$8_1;
  }
  block4 : {
   block3 : {
    i64toi32_i32$1 = $24$hi;
    i64toi32_i32$3 = $24_1;
    i64toi32_i32$2 = 2146435072;
    i64toi32_i32$0 = 0;
    i64toi32_i32$2 = i64toi32_i32$1 & i64toi32_i32$2 | 0;
    i64toi32_i32$1 = i64toi32_i32$3 & i64toi32_i32$0 | 0;
    i64toi32_i32$3 = 2146435072;
    i64toi32_i32$0 = 0;
    if ((i64toi32_i32$1 | 0) != (i64toi32_i32$0 | 0) | (i64toi32_i32$2 | 0) != (i64toi32_i32$3 | 0) | 0) {
     break block3
    }
    $10_1 = $8_1 + 3 | 0;
    $30($0_1 | 0, 32 | 0, $2_1 | 0, $10_1 | 0, $4_1 & -65537 | 0 | 0);
    $24($0_1 | 0, $9_1 | 0, $8_1 | 0);
    $11_1 = $5_1 & 32 | 0;
    $24($0_1 | 0, ($1_1 != $1_1 ? ($11_1 ? 65579 : 65587) : $11_1 ? 65583 : 65591) | 0, 3 | 0);
    $30($0_1 | 0, 32 | 0, $2_1 | 0, $10_1 | 0, $4_1 ^ 8192 | 0 | 0);
    $12_1 = ($2_1 | 0) > ($10_1 | 0) ? $2_1 : $10_1;
    break block4;
   }
   $13_1 = $6_1 + 16 | 0;
   block7 : {
    block8 : {
     block6 : {
      block5 : {
       $1_1 = +$17(+$1_1, $6_1 + 44 | 0 | 0);
       $1_1 = $1_1 + $1_1;
       if ($1_1 == 0.0) {
        break block5
       }
       $10_1 = HEAP32[($6_1 + 44 | 0) >> 2] | 0;
       HEAP32[($6_1 + 44 | 0) >> 2] = $10_1 + -1 | 0;
       $14_1 = $5_1 | 32 | 0;
       if (($14_1 | 0) != (97 | 0)) {
        break block6
       }
       break block7;
      }
      $14_1 = $5_1 | 32 | 0;
      if (($14_1 | 0) == (97 | 0)) {
       break block7
      }
      $15_1 = ($3_1 | 0) < (0 | 0) ? 6 : $3_1;
      $16_1 = HEAP32[($6_1 + 44 | 0) >> 2] | 0;
      break block8;
     }
     $16_1 = $10_1 + -29 | 0;
     HEAP32[($6_1 + 44 | 0) >> 2] = $16_1;
     $15_1 = ($3_1 | 0) < (0 | 0) ? 6 : $3_1;
     $1_1 = $1_1 * 268435456.0;
    }
    $17_1 = ($6_1 + 48 | 0) + (($16_1 | 0) < (0 | 0) ? 0 : 288) | 0;
    $11_1 = $17_1;
    label : while (1) {
     $133 = $11_1;
     if ($1_1 < 4294967295.0 & $1_1 >= 0.0 | 0) {
      $142 = ~~$1_1 >>> 0
     } else {
      $142 = 0
     }
     $10_1 = $142;
     HEAP32[$133 >> 2] = $10_1;
     $11_1 = $11_1 + 4 | 0;
     $1_1 = ($1_1 - +($10_1 >>> 0)) * 1.0e9;
     if ($1_1 != 0.0) {
      continue label
     }
     break label;
    };
    block10 : {
     block9 : {
      if (($16_1 | 0) >= (1 | 0)) {
       break block9
      }
      $18_1 = $16_1;
      $10_1 = $11_1;
      $19_1 = $17_1;
      break block10;
     }
     $19_1 = $17_1;
     $18_1 = $16_1;
     label3 : while (1) {
      $18_1 = $18_1 >>> 0 < 29 >>> 0 ? $18_1 : 29;
      block11 : {
       $10_1 = $11_1 + -4 | 0;
       if ($10_1 >>> 0 < $19_1 >>> 0) {
        break block11
       }
       i64toi32_i32$1 = 0;
       $25_1 = $18_1;
       $25$hi = i64toi32_i32$1;
       i64toi32_i32$1 = 0;
       $24_1 = 0;
       $24$hi = i64toi32_i32$1;
       label1 : while (1) {
        $172 = $10_1;
        i64toi32_i32$0 = $10_1;
        i64toi32_i32$1 = HEAP32[$10_1 >> 2] | 0;
        i64toi32_i32$2 = 0;
        $174$hi = i64toi32_i32$2;
        i64toi32_i32$2 = $25$hi;
        i64toi32_i32$2 = $174$hi;
        i64toi32_i32$0 = i64toi32_i32$1;
        i64toi32_i32$1 = $25$hi;
        i64toi32_i32$3 = $25_1;
        i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
        if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
         i64toi32_i32$1 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
         $49_1 = 0;
        } else {
         i64toi32_i32$1 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$0 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$2 << i64toi32_i32$4 | 0) | 0;
         $49_1 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
        }
        $176$hi = i64toi32_i32$1;
        i64toi32_i32$1 = $24$hi;
        i64toi32_i32$1 = $176$hi;
        i64toi32_i32$2 = $49_1;
        i64toi32_i32$0 = $24$hi;
        i64toi32_i32$3 = $24_1;
        i64toi32_i32$4 = i64toi32_i32$2 + i64toi32_i32$3 | 0;
        i64toi32_i32$5 = i64toi32_i32$1 + i64toi32_i32$0 | 0;
        if (i64toi32_i32$4 >>> 0 < i64toi32_i32$3 >>> 0) {
         i64toi32_i32$5 = i64toi32_i32$5 + 1 | 0
        }
        $26$hi = i64toi32_i32$5;
        i64toi32_i32$2 = 0;
        i64toi32_i32$2 = __wasm_i64_udiv(i64toi32_i32$4 | 0, i64toi32_i32$5 | 0, 1e9 | 0, i64toi32_i32$2 | 0) | 0;
        i64toi32_i32$5 = i64toi32_i32$HIGH_BITS;
        $24_1 = i64toi32_i32$2;
        $24$hi = i64toi32_i32$5;
        i64toi32_i32$2 = 0;
        i64toi32_i32$2 = __wasm_i64_mul($24_1 | 0, i64toi32_i32$5 | 0, 1e9 | 0, i64toi32_i32$2 | 0) | 0;
        i64toi32_i32$5 = i64toi32_i32$HIGH_BITS;
        $183 = i64toi32_i32$2;
        $183$hi = i64toi32_i32$5;
        i64toi32_i32$5 = $26$hi;
        i64toi32_i32$1 = i64toi32_i32$4;
        i64toi32_i32$2 = $183$hi;
        i64toi32_i32$3 = $183;
        i64toi32_i32$0 = i64toi32_i32$1 - i64toi32_i32$3 | 0;
        i64toi32_i32$4 = (i64toi32_i32$1 >>> 0 < i64toi32_i32$3 >>> 0) + i64toi32_i32$2 | 0;
        i64toi32_i32$4 = i64toi32_i32$5 - i64toi32_i32$4 | 0;
        HEAP32[$172 >> 2] = i64toi32_i32$0;
        $10_1 = $10_1 + -4 | 0;
        if ($10_1 >>> 0 >= $19_1 >>> 0) {
         continue label1
        }
        break label1;
       };
       i64toi32_i32$4 = i64toi32_i32$5;
       i64toi32_i32$4 = i64toi32_i32$5;
       i64toi32_i32$5 = i64toi32_i32$1;
       i64toi32_i32$1 = 0;
       i64toi32_i32$3 = 1e9;
       if (i64toi32_i32$4 >>> 0 < i64toi32_i32$1 >>> 0 | ((i64toi32_i32$4 | 0) == (i64toi32_i32$1 | 0) & i64toi32_i32$5 >>> 0 < i64toi32_i32$3 >>> 0 | 0) | 0) {
        break block11
       }
       $19_1 = $19_1 + -4 | 0;
       i64toi32_i32$5 = $24$hi;
       HEAP32[$19_1 >> 2] = $24_1;
      }
      block12 : {
       label2 : while (1) {
        $10_1 = $11_1;
        if ($10_1 >>> 0 <= $19_1 >>> 0) {
         break block12
        }
        $11_1 = $10_1 + -4 | 0;
        if (!(HEAP32[$11_1 >> 2] | 0)) {
         continue label2
        }
        break label2;
       };
      }
      $18_1 = (HEAP32[($6_1 + 44 | 0) >> 2] | 0) - $18_1 | 0;
      HEAP32[($6_1 + 44 | 0) >> 2] = $18_1;
      $11_1 = $10_1;
      if (($18_1 | 0) > (0 | 0)) {
       continue label3
      }
      break label3;
     };
    }
    block13 : {
     if (($18_1 | 0) > (-1 | 0)) {
      break block13
     }
     $20_1 = ((($15_1 + 25 | 0) >>> 0) / (9 >>> 0) | 0) + 1 | 0;
     $21_1 = ($14_1 | 0) == (102 | 0);
     label5 : while (1) {
      $11_1 = 0 - $18_1 | 0;
      $12_1 = $11_1 >>> 0 < 9 >>> 0 ? $11_1 : 9;
      block15 : {
       block14 : {
        if ($19_1 >>> 0 < $10_1 >>> 0) {
         break block14
        }
        $11_1 = HEAP32[$19_1 >> 2] | 0 ? 0 : 4;
        break block15;
       }
       $22_1 = 1e9 >>> $12_1 | 0;
       $23_1 = (-1 << $12_1 | 0) ^ -1 | 0;
       $18_1 = 0;
       $11_1 = $19_1;
       label4 : while (1) {
        $3_1 = HEAP32[$11_1 >> 2] | 0;
        HEAP32[$11_1 >> 2] = ($3_1 >>> $12_1 | 0) + $18_1 | 0;
        $18_1 = Math_imul($3_1 & $23_1 | 0, $22_1);
        $11_1 = $11_1 + 4 | 0;
        if ($11_1 >>> 0 < $10_1 >>> 0) {
         continue label4
        }
        break label4;
       };
       $11_1 = HEAP32[$19_1 >> 2] | 0 ? 0 : 4;
       if (!$18_1) {
        break block15
       }
       HEAP32[$10_1 >> 2] = $18_1;
       $10_1 = $10_1 + 4 | 0;
      }
      $18_1 = (HEAP32[($6_1 + 44 | 0) >> 2] | 0) + $12_1 | 0;
      HEAP32[($6_1 + 44 | 0) >> 2] = $18_1;
      $19_1 = $19_1 + $11_1 | 0;
      $11_1 = $21_1 ? $17_1 : $19_1;
      $10_1 = (($10_1 - $11_1 | 0) >> 2 | 0 | 0) > ($20_1 | 0) ? $11_1 + ($20_1 << 2 | 0) | 0 : $10_1;
      if (($18_1 | 0) < (0 | 0)) {
       continue label5
      }
      break label5;
     };
    }
    $18_1 = 0;
    block16 : {
     if ($19_1 >>> 0 >= $10_1 >>> 0) {
      break block16
     }
     $18_1 = Math_imul(($17_1 - $19_1 | 0) >> 2 | 0, 9);
     $11_1 = 10;
     $3_1 = HEAP32[$19_1 >> 2] | 0;
     if ($3_1 >>> 0 < 10 >>> 0) {
      break block16
     }
     label6 : while (1) {
      $18_1 = $18_1 + 1 | 0;
      $11_1 = Math_imul($11_1, 10);
      if ($3_1 >>> 0 >= $11_1 >>> 0) {
       continue label6
      }
      break label6;
     };
    }
    block17 : {
     $11_1 = ($15_1 - (($14_1 | 0) == (102 | 0) ? 0 : $18_1) | 0) - (($15_1 | 0) != (0 | 0) & ($14_1 | 0) == (103 | 0) | 0) | 0;
     if (($11_1 | 0) >= (Math_imul(($10_1 - $17_1 | 0) >> 2 | 0, 9) + -9 | 0 | 0)) {
      break block17
     }
     $3_1 = $11_1 + 9216 | 0;
     $22_1 = ($3_1 | 0) / (9 | 0) | 0;
     $12_1 = (($6_1 + 48 | 0) + (($16_1 | 0) < (0 | 0) ? -4092 : -3804) | 0) + ($22_1 << 2 | 0) | 0;
     $11_1 = 10;
     block18 : {
      $3_1 = $3_1 - Math_imul($22_1, 9) | 0;
      if (($3_1 | 0) > (7 | 0)) {
       break block18
      }
      label7 : while (1) {
       $11_1 = Math_imul($11_1, 10);
       $3_1 = $3_1 + 1 | 0;
       if (($3_1 | 0) != (8 | 0)) {
        continue label7
       }
       break label7;
      };
     }
     $23_1 = $12_1 + 4 | 0;
     block20 : {
      block19 : {
       $3_1 = HEAP32[$12_1 >> 2] | 0;
       $20_1 = ($3_1 >>> 0) / ($11_1 >>> 0) | 0;
       $22_1 = $3_1 - Math_imul($20_1, $11_1) | 0;
       if ($22_1) {
        break block19
       }
       if (($23_1 | 0) == ($10_1 | 0)) {
        break block20
       }
      }
      block22 : {
       block21 : {
        if ($20_1 & 1 | 0) {
         break block21
        }
        $1_1 = 9007199254740992.0;
        if (($11_1 | 0) != (1e9 | 0)) {
         break block22
        }
        if ($12_1 >>> 0 <= $19_1 >>> 0) {
         break block22
        }
        if (!((HEAPU8[($12_1 + -4 | 0) >> 0] | 0) & 1 | 0)) {
         break block22
        }
       }
       $1_1 = 9007199254740994.0;
      }
      $389 = ($23_1 | 0) == ($10_1 | 0) ? 1.0 : 1.5;
      $23_1 = $11_1 >>> 1 | 0;
      $27_1 = $22_1 >>> 0 < $23_1 >>> 0 ? .5 : ($22_1 | 0) == ($23_1 | 0) ? $389 : 1.5;
      block23 : {
       if ($7_1) {
        break block23
       }
       if ((HEAPU8[$9_1 >> 0] | 0 | 0) != (45 | 0)) {
        break block23
       }
       $27_1 = -$27_1;
       $1_1 = -$1_1;
      }
      $3_1 = $3_1 - $22_1 | 0;
      HEAP32[$12_1 >> 2] = $3_1;
      if ($1_1 + $27_1 == $1_1) {
       break block20
      }
      $11_1 = $3_1 + $11_1 | 0;
      HEAP32[$12_1 >> 2] = $11_1;
      block24 : {
       if ($11_1 >>> 0 < 1e9 >>> 0) {
        break block24
       }
       label8 : while (1) {
        HEAP32[$12_1 >> 2] = 0;
        block25 : {
         $12_1 = $12_1 + -4 | 0;
         if ($12_1 >>> 0 >= $19_1 >>> 0) {
          break block25
         }
         $19_1 = $19_1 + -4 | 0;
         HEAP32[$19_1 >> 2] = 0;
        }
        $11_1 = (HEAP32[$12_1 >> 2] | 0) + 1 | 0;
        HEAP32[$12_1 >> 2] = $11_1;
        if ($11_1 >>> 0 > 999999999 >>> 0) {
         continue label8
        }
        break label8;
       };
      }
      $18_1 = Math_imul(($17_1 - $19_1 | 0) >> 2 | 0, 9);
      $11_1 = 10;
      $3_1 = HEAP32[$19_1 >> 2] | 0;
      if ($3_1 >>> 0 < 10 >>> 0) {
       break block20
      }
      label9 : while (1) {
       $18_1 = $18_1 + 1 | 0;
       $11_1 = Math_imul($11_1, 10);
       if ($3_1 >>> 0 >= $11_1 >>> 0) {
        continue label9
       }
       break label9;
      };
     }
     $11_1 = $12_1 + 4 | 0;
     $10_1 = $10_1 >>> 0 > $11_1 >>> 0 ? $11_1 : $10_1;
    }
    block26 : {
     label10 : while (1) {
      $11_1 = $10_1;
      $3_1 = $10_1 >>> 0 <= $19_1 >>> 0;
      if ($3_1) {
       break block26
      }
      $10_1 = $10_1 + -4 | 0;
      if (!(HEAP32[$10_1 >> 2] | 0)) {
       continue label10
      }
      break label10;
     };
    }
    block28 : {
     block27 : {
      if (($14_1 | 0) == (103 | 0)) {
       break block27
      }
      $22_1 = $4_1 & 8 | 0;
      break block28;
     }
     $10_1 = $15_1 ? $15_1 : 1;
     $12_1 = ($10_1 | 0) > ($18_1 | 0) & ($18_1 | 0) > (-5 | 0) | 0;
     $15_1 = ($12_1 ? $18_1 ^ -1 | 0 : -1) + $10_1 | 0;
     $5_1 = ($12_1 ? -1 : -2) + $5_1 | 0;
     $22_1 = $4_1 & 8 | 0;
     if ($22_1) {
      break block28
     }
     $10_1 = -9;
     block29 : {
      if ($3_1) {
       break block29
      }
      $12_1 = HEAP32[($11_1 + -4 | 0) >> 2] | 0;
      if (!$12_1) {
       break block29
      }
      $3_1 = 10;
      $10_1 = 0;
      if (($12_1 >>> 0) % (10 >>> 0) | 0) {
       break block29
      }
      label11 : while (1) {
       $22_1 = $10_1;
       $10_1 = $10_1 + 1 | 0;
       $3_1 = Math_imul($3_1, 10);
       if (!(($12_1 >>> 0) % ($3_1 >>> 0) | 0)) {
        continue label11
       }
       break label11;
      };
      $10_1 = $22_1 ^ -1 | 0;
     }
     $3_1 = Math_imul(($11_1 - $17_1 | 0) >> 2 | 0, 9);
     block30 : {
      if (($5_1 & -33 | 0 | 0) != (70 | 0)) {
       break block30
      }
      $22_1 = 0;
      $10_1 = ($3_1 + $10_1 | 0) + -9 | 0;
      $10_1 = ($10_1 | 0) > (0 | 0) ? $10_1 : 0;
      $15_1 = ($15_1 | 0) < ($10_1 | 0) ? $15_1 : $10_1;
      break block28;
     }
     $22_1 = 0;
     $10_1 = (($18_1 + $3_1 | 0) + $10_1 | 0) + -9 | 0;
     $10_1 = ($10_1 | 0) > (0 | 0) ? $10_1 : 0;
     $15_1 = ($15_1 | 0) < ($10_1 | 0) ? $15_1 : $10_1;
    }
    $12_1 = -1;
    $23_1 = $15_1 | $22_1 | 0;
    if (($15_1 | 0) > (($23_1 ? 2147483645 : 2147483646) | 0)) {
     break block4
    }
    $3_1 = ($15_1 + (($23_1 | 0) != (0 | 0)) | 0) + 1 | 0;
    block32 : {
     block31 : {
      $21_1 = $5_1 & -33 | 0;
      if (($21_1 | 0) != (70 | 0)) {
       break block31
      }
      if (($18_1 | 0) > ($3_1 ^ 2147483647 | 0 | 0)) {
       break block4
      }
      $10_1 = ($18_1 | 0) > (0 | 0) ? $18_1 : 0;
      break block32;
     }
     block33 : {
      $10_1 = $18_1 >> 31 | 0;
      i64toi32_i32$5 = 0;
      $10_1 = $29(($18_1 ^ $10_1 | 0) - $10_1 | 0 | 0, i64toi32_i32$5 | 0, $13_1 | 0) | 0;
      if (($13_1 - $10_1 | 0 | 0) > (1 | 0)) {
       break block33
      }
      label12 : while (1) {
       $10_1 = $10_1 + -1 | 0;
       HEAP8[$10_1 >> 0] = 48;
       if (($13_1 - $10_1 | 0 | 0) < (2 | 0)) {
        continue label12
       }
       break label12;
      };
     }
     $20_1 = $10_1 + -2 | 0;
     HEAP8[$20_1 >> 0] = $5_1;
     $12_1 = -1;
     HEAP8[($10_1 + -1 | 0) >> 0] = ($18_1 | 0) < (0 | 0) ? 45 : 43;
     $10_1 = $13_1 - $20_1 | 0;
     if (($10_1 | 0) > ($3_1 ^ 2147483647 | 0 | 0)) {
      break block4
     }
    }
    $12_1 = -1;
    $10_1 = $10_1 + $3_1 | 0;
    if (($10_1 | 0) > ($8_1 ^ 2147483647 | 0 | 0)) {
     break block4
    }
    $5_1 = $10_1 + $8_1 | 0;
    $30($0_1 | 0, 32 | 0, $2_1 | 0, $5_1 | 0, $4_1 | 0);
    $24($0_1 | 0, $9_1 | 0, $8_1 | 0);
    $30($0_1 | 0, 48 | 0, $2_1 | 0, $5_1 | 0, $4_1 ^ 65536 | 0 | 0);
    block45 : {
     block40 : {
      block38 : {
       block34 : {
        if (($21_1 | 0) != (70 | 0)) {
         break block34
        }
        $18_1 = $6_1 + 16 | 0 | 9 | 0;
        $3_1 = $19_1 >>> 0 > $17_1 >>> 0 ? $17_1 : $19_1;
        $19_1 = $3_1;
        label14 : while (1) {
         i64toi32_i32$3 = $19_1;
         i64toi32_i32$5 = HEAP32[$19_1 >> 2] | 0;
         i64toi32_i32$4 = 0;
         $10_1 = $29(i64toi32_i32$5 | 0, i64toi32_i32$4 | 0, $18_1 | 0) | 0;
         block36 : {
          block35 : {
           if (($19_1 | 0) == ($3_1 | 0)) {
            break block35
           }
           if ($10_1 >>> 0 <= ($6_1 + 16 | 0) >>> 0) {
            break block36
           }
           label13 : while (1) {
            $10_1 = $10_1 + -1 | 0;
            HEAP8[$10_1 >> 0] = 48;
            if ($10_1 >>> 0 > ($6_1 + 16 | 0) >>> 0) {
             continue label13
            }
            break block36;
           };
          }
          if (($10_1 | 0) != ($18_1 | 0)) {
           break block36
          }
          $10_1 = $10_1 + -1 | 0;
          HEAP8[$10_1 >> 0] = 48;
         }
         $24($0_1 | 0, $10_1 | 0, $18_1 - $10_1 | 0 | 0);
         $19_1 = $19_1 + 4 | 0;
         if ($19_1 >>> 0 <= $17_1 >>> 0) {
          continue label14
         }
         break label14;
        };
        block37 : {
         if (!$23_1) {
          break block37
         }
         $24($0_1 | 0, 65595 | 0, 1 | 0);
        }
        if ($19_1 >>> 0 >= $11_1 >>> 0) {
         break block38
        }
        if (($15_1 | 0) < (1 | 0)) {
         break block38
        }
        label16 : while (1) {
         block39 : {
          i64toi32_i32$3 = $19_1;
          i64toi32_i32$4 = HEAP32[$19_1 >> 2] | 0;
          i64toi32_i32$5 = 0;
          $10_1 = $29(i64toi32_i32$4 | 0, i64toi32_i32$5 | 0, $18_1 | 0) | 0;
          if ($10_1 >>> 0 <= ($6_1 + 16 | 0) >>> 0) {
           break block39
          }
          label15 : while (1) {
           $10_1 = $10_1 + -1 | 0;
           HEAP8[$10_1 >> 0] = 48;
           if ($10_1 >>> 0 > ($6_1 + 16 | 0) >>> 0) {
            continue label15
           }
           break label15;
          };
         }
         $24($0_1 | 0, $10_1 | 0, (($15_1 | 0) < (9 | 0) ? $15_1 : 9) | 0);
         $10_1 = $15_1 + -9 | 0;
         $19_1 = $19_1 + 4 | 0;
         if ($19_1 >>> 0 >= $11_1 >>> 0) {
          break block40
         }
         $3_1 = ($15_1 | 0) > (9 | 0);
         $15_1 = $10_1;
         if ($3_1) {
          continue label16
         }
         break block40;
        };
       }
       block41 : {
        if (($15_1 | 0) < (0 | 0)) {
         break block41
        }
        $12_1 = $11_1 >>> 0 > $19_1 >>> 0 ? $11_1 : $19_1 + 4 | 0;
        $18_1 = $6_1 + 16 | 0 | 9 | 0;
        $11_1 = $19_1;
        label18 : while (1) {
         block42 : {
          i64toi32_i32$3 = $11_1;
          i64toi32_i32$5 = HEAP32[$11_1 >> 2] | 0;
          i64toi32_i32$4 = 0;
          $10_1 = $29(i64toi32_i32$5 | 0, i64toi32_i32$4 | 0, $18_1 | 0) | 0;
          if (($10_1 | 0) != ($18_1 | 0)) {
           break block42
          }
          $10_1 = $10_1 + -1 | 0;
          HEAP8[$10_1 >> 0] = 48;
         }
         block44 : {
          block43 : {
           if (($11_1 | 0) == ($19_1 | 0)) {
            break block43
           }
           if ($10_1 >>> 0 <= ($6_1 + 16 | 0) >>> 0) {
            break block44
           }
           label17 : while (1) {
            $10_1 = $10_1 + -1 | 0;
            HEAP8[$10_1 >> 0] = 48;
            if ($10_1 >>> 0 > ($6_1 + 16 | 0) >>> 0) {
             continue label17
            }
            break block44;
           };
          }
          $24($0_1 | 0, $10_1 | 0, 1 | 0);
          $10_1 = $10_1 + 1 | 0;
          if (!($15_1 | $22_1 | 0)) {
           break block44
          }
          $24($0_1 | 0, 65595 | 0, 1 | 0);
         }
         $3_1 = $18_1 - $10_1 | 0;
         $24($0_1 | 0, $10_1 | 0, (($15_1 | 0) > ($3_1 | 0) ? $3_1 : $15_1) | 0);
         $15_1 = $15_1 - $3_1 | 0;
         $11_1 = $11_1 + 4 | 0;
         if ($11_1 >>> 0 >= $12_1 >>> 0) {
          break block41
         }
         if (($15_1 | 0) > (-1 | 0)) {
          continue label18
         }
         break label18;
        };
       }
       $30($0_1 | 0, 48 | 0, $15_1 + 18 | 0 | 0, 18 | 0, 0 | 0);
       $24($0_1 | 0, $20_1 | 0, $13_1 - $20_1 | 0 | 0);
       break block45;
      }
      $10_1 = $15_1;
     }
     $30($0_1 | 0, 48 | 0, $10_1 + 9 | 0 | 0, 9 | 0, 0 | 0);
    }
    $30($0_1 | 0, 32 | 0, $2_1 | 0, $5_1 | 0, $4_1 ^ 8192 | 0 | 0);
    $12_1 = ($2_1 | 0) > ($5_1 | 0) ? $2_1 : $5_1;
    break block4;
   }
   $20_1 = $9_1 + ((($5_1 << 26 | 0) >> 31 | 0) & 9 | 0) | 0;
   block46 : {
    if ($3_1 >>> 0 > 11 >>> 0) {
     break block46
    }
    $10_1 = 12 - $3_1 | 0;
    $27_1 = 16.0;
    label19 : while (1) {
     $27_1 = $27_1 * 16.0;
     $10_1 = $10_1 + -1 | 0;
     if ($10_1) {
      continue label19
     }
     break label19;
    };
    block47 : {
     if ((HEAPU8[$20_1 >> 0] | 0 | 0) != (45 | 0)) {
      break block47
     }
     $1_1 = -($27_1 + (-$1_1 - $27_1));
     break block46;
    }
    $1_1 = $1_1 + $27_1 - $27_1;
   }
   block48 : {
    $11_1 = HEAP32[($6_1 + 44 | 0) >> 2] | 0;
    $10_1 = $11_1 >> 31 | 0;
    i64toi32_i32$4 = 0;
    $10_1 = $29(($11_1 ^ $10_1 | 0) - $10_1 | 0 | 0, i64toi32_i32$4 | 0, $13_1 | 0) | 0;
    if (($10_1 | 0) != ($13_1 | 0)) {
     break block48
    }
    $10_1 = $10_1 + -1 | 0;
    HEAP8[$10_1 >> 0] = 48;
    $11_1 = HEAP32[($6_1 + 44 | 0) >> 2] | 0;
   }
   $22_1 = $8_1 | 2 | 0;
   $19_1 = $5_1 & 32 | 0;
   $23_1 = $10_1 + -2 | 0;
   HEAP8[$23_1 >> 0] = $5_1 + 15 | 0;
   HEAP8[($10_1 + -1 | 0) >> 0] = ($11_1 | 0) < (0 | 0) ? 45 : 43;
   $18_1 = ($3_1 | 0) < (1 | 0) & !($4_1 & 8 | 0) | 0;
   $11_1 = $6_1 + 16 | 0;
   label20 : while (1) {
    $10_1 = $11_1;
    $890 = $10_1;
    if (Math_abs($1_1) < 2147483647.0) {
     $897 = ~~$1_1
    } else {
     $897 = -2147483648
    }
    $11_1 = $897;
    HEAP8[$890 >> 0] = HEAPU8[($11_1 + 66128 | 0) >> 0] | 0 | $19_1 | 0;
    $1_1 = ($1_1 - +($11_1 | 0)) * 16.0;
    block49 : {
     $11_1 = $10_1 + 1 | 0;
     if (($11_1 - ($6_1 + 16 | 0) | 0 | 0) != (1 | 0)) {
      break block49
     }
     if ($1_1 == 0.0 & $18_1 | 0) {
      break block49
     }
     HEAP8[($10_1 + 1 | 0) >> 0] = 46;
     $11_1 = $10_1 + 2 | 0;
    }
    if ($1_1 != 0.0) {
     continue label20
    }
    break label20;
   };
   $12_1 = -1;
   $19_1 = $13_1 - $23_1 | 0;
   $18_1 = $22_1 + $19_1 | 0;
   if (($3_1 | 0) > (2147483645 - $18_1 | 0 | 0)) {
    break block4
   }
   $10_1 = $11_1 - ($6_1 + 16 | 0) | 0;
   $3_1 = $3_1 ? (($10_1 + -2 | 0 | 0) < ($3_1 | 0) ? $3_1 + 2 | 0 : $10_1) : $10_1;
   $11_1 = $18_1 + $3_1 | 0;
   $30($0_1 | 0, 32 | 0, $2_1 | 0, $11_1 | 0, $4_1 | 0);
   $24($0_1 | 0, $20_1 | 0, $22_1 | 0);
   $30($0_1 | 0, 48 | 0, $2_1 | 0, $11_1 | 0, $4_1 ^ 65536 | 0 | 0);
   $24($0_1 | 0, $6_1 + 16 | 0 | 0, $10_1 | 0);
   $30($0_1 | 0, 48 | 0, $3_1 - $10_1 | 0 | 0, 0 | 0, 0 | 0);
   $24($0_1 | 0, $23_1 | 0, $19_1 | 0);
   $30($0_1 | 0, 32 | 0, $2_1 | 0, $11_1 | 0, $4_1 ^ 8192 | 0 | 0);
   $12_1 = ($2_1 | 0) > ($11_1 | 0) ? $2_1 : $11_1;
  }
  global$0 = $6_1 + 560 | 0;
  return $12_1 | 0;
 }
 
 function $33($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$2 = 0, $2_1 = 0, $12_1 = 0, $12$hi = 0, $14_1 = 0, $14$hi = 0, wasm2js_i32$0 = 0, wasm2js_f64$0 = 0.0;
  $2_1 = ((HEAP32[$1_1 >> 2] | 0) + 7 | 0) & -8 | 0;
  HEAP32[$1_1 >> 2] = $2_1 + 16 | 0;
  i64toi32_i32$2 = $2_1;
  i64toi32_i32$0 = HEAP32[i64toi32_i32$2 >> 2] | 0;
  i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 4 | 0) >> 2] | 0;
  $12_1 = i64toi32_i32$0;
  $12$hi = i64toi32_i32$1;
  i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 8 | 0) >> 2] | 0;
  i64toi32_i32$0 = HEAP32[(i64toi32_i32$2 + 12 | 0) >> 2] | 0;
  $14_1 = i64toi32_i32$1;
  $14$hi = i64toi32_i32$0;
  i64toi32_i32$0 = $12$hi;
  i64toi32_i32$1 = $14$hi;
  (wasm2js_i32$0 = $0_1, wasm2js_f64$0 = +$58($12_1 | 0, i64toi32_i32$0 | 0, $14_1 | 0, i64toi32_i32$1 | 0)), HEAPF64[wasm2js_i32$0 >> 3] = wasm2js_f64$0;
 }
 
 function $34($0_1) {
  $0_1 = +$0_1;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0;
  wasm2js_scratch_store_f64(+$0_1);
  i64toi32_i32$0 = wasm2js_scratch_load_i32(1 | 0) | 0;
  i64toi32_i32$1 = wasm2js_scratch_load_i32(0 | 0) | 0;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$0;
  return i64toi32_i32$1 | 0;
 }
 
 function $35($0_1) {
  $0_1 = $0_1 | 0;
  var wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  block : {
   if ($0_1) {
    break block
   }
   return 0 | 0;
  }
  (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = $0_1), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
  return -1 | 0;
 }
 
 function $36() {
  return 42 | 0;
 }
 
 function $37() {
  return $36() | 0 | 0;
 }
 
 function $38() {
  return 69756 | 0;
 }
 
 function $39() {
  var $0_1 = 0;
  HEAP32[(0 + 69852 | 0) >> 2] = 69732;
  $0_1 = $37() | 0;
  HEAP32[(0 + 69812 | 0) >> 2] = 65536 - 0 | 0;
  HEAP32[(0 + 69808 | 0) >> 2] = 65536;
  HEAP32[(0 + 69780 | 0) >> 2] = $0_1;
  HEAP32[(0 + 69816 | 0) >> 2] = HEAP32[(0 + 68500 | 0) >> 2] | 0;
 }
 
 function $40($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $3_1 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  $3_1 = 1;
  block1 : {
   block : {
    if (!$0_1) {
     break block
    }
    if ($1_1 >>> 0 <= 127 >>> 0) {
     break block1
    }
    block3 : {
     block2 : {
      if (HEAP32[(HEAP32[(($38() | 0) + 96 | 0) >> 2] | 0) >> 2] | 0) {
       break block2
      }
      if (($1_1 & -128 | 0 | 0) == (57216 | 0)) {
       break block1
      }
      (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = 25), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
      break block3;
     }
     block4 : {
      if ($1_1 >>> 0 > 2047 >>> 0) {
       break block4
      }
      HEAP8[($0_1 + 1 | 0) >> 0] = $1_1 & 63 | 0 | 128 | 0;
      HEAP8[$0_1 >> 0] = $1_1 >>> 6 | 0 | 192 | 0;
      return 2 | 0;
     }
     block6 : {
      block5 : {
       if ($1_1 >>> 0 < 55296 >>> 0) {
        break block5
       }
       if (($1_1 & -8192 | 0 | 0) != (57344 | 0)) {
        break block6
       }
      }
      HEAP8[($0_1 + 2 | 0) >> 0] = $1_1 & 63 | 0 | 128 | 0;
      HEAP8[$0_1 >> 0] = $1_1 >>> 12 | 0 | 224 | 0;
      HEAP8[($0_1 + 1 | 0) >> 0] = ($1_1 >>> 6 | 0) & 63 | 0 | 128 | 0;
      return 3 | 0;
     }
     block7 : {
      if (($1_1 + -65536 | 0) >>> 0 > 1048575 >>> 0) {
       break block7
      }
      HEAP8[($0_1 + 3 | 0) >> 0] = $1_1 & 63 | 0 | 128 | 0;
      HEAP8[$0_1 >> 0] = $1_1 >>> 18 | 0 | 240 | 0;
      HEAP8[($0_1 + 2 | 0) >> 0] = ($1_1 >>> 6 | 0) & 63 | 0 | 128 | 0;
      HEAP8[($0_1 + 1 | 0) >> 0] = ($1_1 >>> 12 | 0) & 63 | 0 | 128 | 0;
      return 4 | 0;
     }
     (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = 25), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
    }
    $3_1 = -1;
   }
   return $3_1 | 0;
  }
  HEAP8[$0_1 >> 0] = $1_1;
  return 1 | 0;
 }
 
 function $41($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  block : {
   if ($0_1) {
    break block
   }
   return 0 | 0;
  }
  return $40($0_1 | 0, $1_1 | 0, 0 | 0) | 0 | 0;
 }
 
 function $42() {
  fimport$1();
  wasm2js_trap();
 }
 
 function $43($0_1) {
  $0_1 = $0_1 | 0;
  return $0_1 | 0;
 }
 
 function $44($0_1) {
  $0_1 = $0_1 | 0;
  return $35(fimport$2($43(HEAP32[($0_1 + 60 | 0) >> 2] | 0 | 0) | 0 | 0) | 0 | 0) | 0 | 0;
 }
 
 function $45($0_1, $1_1, $1$hi, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$2 = 0, $3_1 = 0, i64toi32_i32$1 = 0, i64toi32_i32$3 = 0;
  $3_1 = global$0 - 16 | 0;
  global$0 = $3_1;
  i64toi32_i32$0 = $1$hi;
  $2_1 = $35($69($0_1 | 0, $1_1 | 0, i64toi32_i32$0 | 0, $2_1 & 255 | 0 | 0, $3_1 + 8 | 0 | 0) | 0 | 0) | 0;
  i64toi32_i32$2 = $3_1;
  i64toi32_i32$0 = HEAP32[(i64toi32_i32$2 + 8 | 0) >> 2] | 0;
  i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 12 | 0) >> 2] | 0;
  $1_1 = i64toi32_i32$0;
  $1$hi = i64toi32_i32$1;
  global$0 = i64toi32_i32$2 + 16 | 0;
  i64toi32_i32$1 = -1;
  i64toi32_i32$0 = $1$hi;
  i64toi32_i32$3 = $2_1 ? -1 : $1_1;
  i64toi32_i32$2 = $2_1 ? i64toi32_i32$1 : i64toi32_i32$0;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$2;
  return i64toi32_i32$3 | 0;
 }
 
 function $46($0_1, $1_1, $1$hi, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0;
  i64toi32_i32$0 = $1$hi;
  i64toi32_i32$0 = $45(HEAP32[($0_1 + 60 | 0) >> 2] | 0 | 0, $1_1 | 0, i64toi32_i32$0 | 0, $2_1 | 0) | 0;
  i64toi32_i32$1 = i64toi32_i32$HIGH_BITS;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
  return i64toi32_i32$0 | 0;
 }
 
 function $47($0_1) {
  $0_1 = $0_1 | 0;
  var $6_1 = 0, $4_1 = 0, $5_1 = 0, $8_1 = 0, $3_1 = 0, $2_1 = 0, $7_1 = 0, $12_1 = 0, $11_1 = 0, i64toi32_i32$1 = 0, i64toi32_i32$0 = 0, $10_1 = 0, i64toi32_i32$2 = 0, $1_1 = 0, $9_1 = 0, $84 = 0, $194 = 0, $1142 = 0, $1144 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  $1_1 = global$0 - 16 | 0;
  global$0 = $1_1;
  block5 : {
   block88 : {
    block4 : {
     block6 : {
      block : {
       if ($0_1 >>> 0 > 244 >>> 0) {
        break block
       }
       block1 : {
        $2_1 = HEAP32[(0 + 69896 | 0) >> 2] | 0;
        $3_1 = $0_1 >>> 0 < 11 >>> 0 ? 16 : ($0_1 + 11 | 0) & 504 | 0;
        $4_1 = $3_1 >>> 3 | 0;
        $0_1 = $2_1 >>> $4_1 | 0;
        if (!($0_1 & 3 | 0)) {
         break block1
        }
        block3 : {
         block2 : {
          $5_1 = (($0_1 ^ -1 | 0) & 1 | 0) + $4_1 | 0;
          $3_1 = $5_1 << 3 | 0;
          $6_1 = $3_1 + 69936 | 0;
          $4_1 = HEAP32[($3_1 + 69944 | 0) >> 2] | 0;
          $0_1 = HEAP32[($4_1 + 8 | 0) >> 2] | 0;
          if (($6_1 | 0) != ($0_1 | 0)) {
           break block2
          }
          (wasm2js_i32$0 = 0, wasm2js_i32$1 = $2_1 & (__wasm_rotl_i32(-2 | 0, $5_1 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69896 | 0) >> 2] = wasm2js_i32$1;
          break block3;
         }
         if ($0_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
          break block4
         }
         if ((HEAP32[($0_1 + 12 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block4
         }
         HEAP32[($0_1 + 12 | 0) >> 2] = $6_1;
         HEAP32[($6_1 + 8 | 0) >> 2] = $0_1;
        }
        $0_1 = $4_1 + 8 | 0;
        HEAP32[($4_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
        $4_1 = $4_1 + $3_1 | 0;
        HEAP32[($4_1 + 4 | 0) >> 2] = HEAP32[($4_1 + 4 | 0) >> 2] | 0 | 1 | 0;
        break block5;
       }
       $7_1 = HEAP32[(0 + 69904 | 0) >> 2] | 0;
       if ($3_1 >>> 0 <= $7_1 >>> 0) {
        break block6
       }
       block7 : {
        if (!$0_1) {
         break block7
        }
        block9 : {
         block8 : {
          $84 = $0_1 << $4_1 | 0;
          $0_1 = 2 << $4_1 | 0;
          $8_1 = __wasm_ctz_i32($84 & ($0_1 | (0 - $0_1 | 0) | 0) | 0 | 0) | 0;
          $4_1 = $8_1 << 3 | 0;
          $5_1 = $4_1 + 69936 | 0;
          $0_1 = HEAP32[($4_1 + 69944 | 0) >> 2] | 0;
          $6_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
          if (($5_1 | 0) != ($6_1 | 0)) {
           break block8
          }
          $2_1 = $2_1 & (__wasm_rotl_i32(-2 | 0, $8_1 | 0) | 0) | 0;
          HEAP32[(0 + 69896 | 0) >> 2] = $2_1;
          break block9;
         }
         if ($6_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
          break block4
         }
         if ((HEAP32[($6_1 + 12 | 0) >> 2] | 0 | 0) != ($0_1 | 0)) {
          break block4
         }
         HEAP32[($6_1 + 12 | 0) >> 2] = $5_1;
         HEAP32[($5_1 + 8 | 0) >> 2] = $6_1;
        }
        HEAP32[($0_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
        $5_1 = $0_1 + $3_1 | 0;
        $3_1 = $4_1 - $3_1 | 0;
        HEAP32[($5_1 + 4 | 0) >> 2] = $3_1 | 1 | 0;
        HEAP32[($0_1 + $4_1 | 0) >> 2] = $3_1;
        block10 : {
         if (!$7_1) {
          break block10
         }
         $6_1 = ($7_1 & -8 | 0) + 69936 | 0;
         $4_1 = HEAP32[(0 + 69916 | 0) >> 2] | 0;
         block12 : {
          block11 : {
           $8_1 = 1 << ($7_1 >>> 3 | 0) | 0;
           if ($2_1 & $8_1 | 0) {
            break block11
           }
           HEAP32[(0 + 69896 | 0) >> 2] = $2_1 | $8_1 | 0;
           $8_1 = $6_1;
           break block12;
          }
          $8_1 = HEAP32[($6_1 + 8 | 0) >> 2] | 0;
          if ($8_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
           break block4
          }
         }
         HEAP32[($6_1 + 8 | 0) >> 2] = $4_1;
         HEAP32[($8_1 + 12 | 0) >> 2] = $4_1;
         HEAP32[($4_1 + 12 | 0) >> 2] = $6_1;
         HEAP32[($4_1 + 8 | 0) >> 2] = $8_1;
        }
        $0_1 = $0_1 + 8 | 0;
        HEAP32[(0 + 69916 | 0) >> 2] = $5_1;
        HEAP32[(0 + 69904 | 0) >> 2] = $3_1;
        break block5;
       }
       $9_1 = HEAP32[(0 + 69900 | 0) >> 2] | 0;
       if (!$9_1) {
        break block6
       }
       $6_1 = HEAP32[(((__wasm_ctz_i32($9_1 | 0) | 0) << 2 | 0) + 70200 | 0) >> 2] | 0;
       $4_1 = ((HEAP32[($6_1 + 4 | 0) >> 2] | 0) & -8 | 0) - $3_1 | 0;
       $5_1 = $6_1;
       block14 : {
        label : while (1) {
         block13 : {
          $0_1 = HEAP32[($6_1 + 16 | 0) >> 2] | 0;
          if ($0_1) {
           break block13
          }
          $0_1 = HEAP32[($6_1 + 20 | 0) >> 2] | 0;
          if (!$0_1) {
           break block14
          }
         }
         $6_1 = ((HEAP32[($0_1 + 4 | 0) >> 2] | 0) & -8 | 0) - $3_1 | 0;
         $194 = $6_1;
         $6_1 = $6_1 >>> 0 < $4_1 >>> 0;
         $4_1 = $6_1 ? $194 : $4_1;
         $5_1 = $6_1 ? $0_1 : $5_1;
         $6_1 = $0_1;
         continue label;
        };
       }
       $10_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
       if ($5_1 >>> 0 < $10_1 >>> 0) {
        break block4
       }
       $11_1 = HEAP32[($5_1 + 24 | 0) >> 2] | 0;
       block16 : {
        block15 : {
         $0_1 = HEAP32[($5_1 + 12 | 0) >> 2] | 0;
         if (($0_1 | 0) == ($5_1 | 0)) {
          break block15
         }
         $6_1 = HEAP32[($5_1 + 8 | 0) >> 2] | 0;
         if ($6_1 >>> 0 < $10_1 >>> 0) {
          break block4
         }
         if ((HEAP32[($6_1 + 12 | 0) >> 2] | 0 | 0) != ($5_1 | 0)) {
          break block4
         }
         if ((HEAP32[($0_1 + 8 | 0) >> 2] | 0 | 0) != ($5_1 | 0)) {
          break block4
         }
         HEAP32[($6_1 + 12 | 0) >> 2] = $0_1;
         HEAP32[($0_1 + 8 | 0) >> 2] = $6_1;
         break block16;
        }
        block19 : {
         block18 : {
          block17 : {
           $6_1 = HEAP32[($5_1 + 20 | 0) >> 2] | 0;
           if (!$6_1) {
            break block17
           }
           $8_1 = $5_1 + 20 | 0;
           break block18;
          }
          $6_1 = HEAP32[($5_1 + 16 | 0) >> 2] | 0;
          if (!$6_1) {
           break block19
          }
          $8_1 = $5_1 + 16 | 0;
         }
         label1 : while (1) {
          $12_1 = $8_1;
          $0_1 = $6_1;
          $8_1 = $0_1 + 20 | 0;
          $6_1 = HEAP32[($0_1 + 20 | 0) >> 2] | 0;
          if ($6_1) {
           continue label1
          }
          $8_1 = $0_1 + 16 | 0;
          $6_1 = HEAP32[($0_1 + 16 | 0) >> 2] | 0;
          if ($6_1) {
           continue label1
          }
          break label1;
         };
         if ($12_1 >>> 0 < $10_1 >>> 0) {
          break block4
         }
         HEAP32[$12_1 >> 2] = 0;
         break block16;
        }
        $0_1 = 0;
       }
       block20 : {
        if (!$11_1) {
         break block20
        }
        block22 : {
         block21 : {
          $8_1 = HEAP32[($5_1 + 28 | 0) >> 2] | 0;
          $6_1 = $8_1 << 2 | 0;
          if (($5_1 | 0) != (HEAP32[($6_1 + 70200 | 0) >> 2] | 0 | 0)) {
           break block21
          }
          HEAP32[($6_1 + 70200 | 0) >> 2] = $0_1;
          if ($0_1) {
           break block22
          }
          (wasm2js_i32$0 = 0, wasm2js_i32$1 = $9_1 & (__wasm_rotl_i32(-2 | 0, $8_1 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69900 | 0) >> 2] = wasm2js_i32$1;
          break block20;
         }
         if ($11_1 >>> 0 < $10_1 >>> 0) {
          break block4
         }
         block24 : {
          block23 : {
           if ((HEAP32[($11_1 + 16 | 0) >> 2] | 0 | 0) != ($5_1 | 0)) {
            break block23
           }
           HEAP32[($11_1 + 16 | 0) >> 2] = $0_1;
           break block24;
          }
          HEAP32[($11_1 + 20 | 0) >> 2] = $0_1;
         }
         if (!$0_1) {
          break block20
         }
        }
        if ($0_1 >>> 0 < $10_1 >>> 0) {
         break block4
        }
        HEAP32[($0_1 + 24 | 0) >> 2] = $11_1;
        block25 : {
         $6_1 = HEAP32[($5_1 + 16 | 0) >> 2] | 0;
         if (!$6_1) {
          break block25
         }
         if ($6_1 >>> 0 < $10_1 >>> 0) {
          break block4
         }
         HEAP32[($0_1 + 16 | 0) >> 2] = $6_1;
         HEAP32[($6_1 + 24 | 0) >> 2] = $0_1;
        }
        $6_1 = HEAP32[($5_1 + 20 | 0) >> 2] | 0;
        if (!$6_1) {
         break block20
        }
        if ($6_1 >>> 0 < $10_1 >>> 0) {
         break block4
        }
        HEAP32[($0_1 + 20 | 0) >> 2] = $6_1;
        HEAP32[($6_1 + 24 | 0) >> 2] = $0_1;
       }
       block27 : {
        block26 : {
         if ($4_1 >>> 0 > 15 >>> 0) {
          break block26
         }
         $0_1 = $4_1 + $3_1 | 0;
         HEAP32[($5_1 + 4 | 0) >> 2] = $0_1 | 3 | 0;
         $0_1 = $5_1 + $0_1 | 0;
         HEAP32[($0_1 + 4 | 0) >> 2] = HEAP32[($0_1 + 4 | 0) >> 2] | 0 | 1 | 0;
         break block27;
        }
        HEAP32[($5_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
        $3_1 = $5_1 + $3_1 | 0;
        HEAP32[($3_1 + 4 | 0) >> 2] = $4_1 | 1 | 0;
        HEAP32[($3_1 + $4_1 | 0) >> 2] = $4_1;
        block28 : {
         if (!$7_1) {
          break block28
         }
         $6_1 = ($7_1 & -8 | 0) + 69936 | 0;
         $0_1 = HEAP32[(0 + 69916 | 0) >> 2] | 0;
         block30 : {
          block29 : {
           $8_1 = 1 << ($7_1 >>> 3 | 0) | 0;
           if ($8_1 & $2_1 | 0) {
            break block29
           }
           HEAP32[(0 + 69896 | 0) >> 2] = $8_1 | $2_1 | 0;
           $8_1 = $6_1;
           break block30;
          }
          $8_1 = HEAP32[($6_1 + 8 | 0) >> 2] | 0;
          if ($8_1 >>> 0 < $10_1 >>> 0) {
           break block4
          }
         }
         HEAP32[($6_1 + 8 | 0) >> 2] = $0_1;
         HEAP32[($8_1 + 12 | 0) >> 2] = $0_1;
         HEAP32[($0_1 + 12 | 0) >> 2] = $6_1;
         HEAP32[($0_1 + 8 | 0) >> 2] = $8_1;
        }
        HEAP32[(0 + 69916 | 0) >> 2] = $3_1;
        HEAP32[(0 + 69904 | 0) >> 2] = $4_1;
       }
       $0_1 = $5_1 + 8 | 0;
       break block5;
      }
      $3_1 = -1;
      if ($0_1 >>> 0 > -65 >>> 0) {
       break block6
      }
      $4_1 = $0_1 + 11 | 0;
      $3_1 = $4_1 & -8 | 0;
      $11_1 = HEAP32[(0 + 69900 | 0) >> 2] | 0;
      if (!$11_1) {
       break block6
      }
      $7_1 = 31;
      block31 : {
       if ($0_1 >>> 0 > 16777204 >>> 0) {
        break block31
       }
       $0_1 = Math_clz32($4_1 >>> 8 | 0);
       $7_1 = ((($3_1 >>> (38 - $0_1 | 0) | 0) & 1 | 0) - ($0_1 << 1 | 0) | 0) + 62 | 0;
      }
      $4_1 = 0 - $3_1 | 0;
      block37 : {
       block35 : {
        block33 : {
         block32 : {
          $6_1 = HEAP32[(($7_1 << 2 | 0) + 70200 | 0) >> 2] | 0;
          if ($6_1) {
           break block32
          }
          $0_1 = 0;
          $8_1 = 0;
          break block33;
         }
         $0_1 = 0;
         $5_1 = $3_1 << (($7_1 | 0) == (31 | 0) ? 0 : 25 - ($7_1 >>> 1 | 0) | 0) | 0;
         $8_1 = 0;
         label2 : while (1) {
          block34 : {
           $2_1 = ((HEAP32[($6_1 + 4 | 0) >> 2] | 0) & -8 | 0) - $3_1 | 0;
           if ($2_1 >>> 0 >= $4_1 >>> 0) {
            break block34
           }
           $4_1 = $2_1;
           $8_1 = $6_1;
           if ($4_1) {
            break block34
           }
           $4_1 = 0;
           $8_1 = $6_1;
           $0_1 = $6_1;
           break block35;
          }
          $2_1 = HEAP32[($6_1 + 20 | 0) >> 2] | 0;
          $12_1 = HEAP32[(($6_1 + (($5_1 >>> 29 | 0) & 4 | 0) | 0) + 16 | 0) >> 2] | 0;
          $0_1 = $2_1 ? (($2_1 | 0) == ($12_1 | 0) ? $0_1 : $2_1) : $0_1;
          $5_1 = $5_1 << 1 | 0;
          $6_1 = $12_1;
          if ($6_1) {
           continue label2
          }
          break label2;
         };
        }
        block36 : {
         if ($0_1 | $8_1 | 0) {
          break block36
         }
         $8_1 = 0;
         $0_1 = 2 << $7_1 | 0;
         $0_1 = ($0_1 | (0 - $0_1 | 0) | 0) & $11_1 | 0;
         if (!$0_1) {
          break block6
         }
         $0_1 = HEAP32[(((__wasm_ctz_i32($0_1 | 0) | 0) << 2 | 0) + 70200 | 0) >> 2] | 0;
        }
        if (!$0_1) {
         break block37
        }
       }
       label3 : while (1) {
        $2_1 = ((HEAP32[($0_1 + 4 | 0) >> 2] | 0) & -8 | 0) - $3_1 | 0;
        $5_1 = $2_1 >>> 0 < $4_1 >>> 0;
        block38 : {
         $6_1 = HEAP32[($0_1 + 16 | 0) >> 2] | 0;
         if ($6_1) {
          break block38
         }
         $6_1 = HEAP32[($0_1 + 20 | 0) >> 2] | 0;
        }
        $4_1 = $5_1 ? $2_1 : $4_1;
        $8_1 = $5_1 ? $0_1 : $8_1;
        $0_1 = $6_1;
        if ($0_1) {
         continue label3
        }
        break label3;
       };
      }
      if (!$8_1) {
       break block6
      }
      if ($4_1 >>> 0 >= ((HEAP32[(0 + 69904 | 0) >> 2] | 0) - $3_1 | 0) >>> 0) {
       break block6
      }
      $12_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
      if ($8_1 >>> 0 < $12_1 >>> 0) {
       break block4
      }
      $7_1 = HEAP32[($8_1 + 24 | 0) >> 2] | 0;
      block40 : {
       block39 : {
        $0_1 = HEAP32[($8_1 + 12 | 0) >> 2] | 0;
        if (($0_1 | 0) == ($8_1 | 0)) {
         break block39
        }
        $6_1 = HEAP32[($8_1 + 8 | 0) >> 2] | 0;
        if ($6_1 >>> 0 < $12_1 >>> 0) {
         break block4
        }
        if ((HEAP32[($6_1 + 12 | 0) >> 2] | 0 | 0) != ($8_1 | 0)) {
         break block4
        }
        if ((HEAP32[($0_1 + 8 | 0) >> 2] | 0 | 0) != ($8_1 | 0)) {
         break block4
        }
        HEAP32[($6_1 + 12 | 0) >> 2] = $0_1;
        HEAP32[($0_1 + 8 | 0) >> 2] = $6_1;
        break block40;
       }
       block43 : {
        block42 : {
         block41 : {
          $6_1 = HEAP32[($8_1 + 20 | 0) >> 2] | 0;
          if (!$6_1) {
           break block41
          }
          $5_1 = $8_1 + 20 | 0;
          break block42;
         }
         $6_1 = HEAP32[($8_1 + 16 | 0) >> 2] | 0;
         if (!$6_1) {
          break block43
         }
         $5_1 = $8_1 + 16 | 0;
        }
        label4 : while (1) {
         $2_1 = $5_1;
         $0_1 = $6_1;
         $5_1 = $0_1 + 20 | 0;
         $6_1 = HEAP32[($0_1 + 20 | 0) >> 2] | 0;
         if ($6_1) {
          continue label4
         }
         $5_1 = $0_1 + 16 | 0;
         $6_1 = HEAP32[($0_1 + 16 | 0) >> 2] | 0;
         if ($6_1) {
          continue label4
         }
         break label4;
        };
        if ($2_1 >>> 0 < $12_1 >>> 0) {
         break block4
        }
        HEAP32[$2_1 >> 2] = 0;
        break block40;
       }
       $0_1 = 0;
      }
      block44 : {
       if (!$7_1) {
        break block44
       }
       block46 : {
        block45 : {
         $5_1 = HEAP32[($8_1 + 28 | 0) >> 2] | 0;
         $6_1 = $5_1 << 2 | 0;
         if (($8_1 | 0) != (HEAP32[($6_1 + 70200 | 0) >> 2] | 0 | 0)) {
          break block45
         }
         HEAP32[($6_1 + 70200 | 0) >> 2] = $0_1;
         if ($0_1) {
          break block46
         }
         $11_1 = $11_1 & (__wasm_rotl_i32(-2 | 0, $5_1 | 0) | 0) | 0;
         HEAP32[(0 + 69900 | 0) >> 2] = $11_1;
         break block44;
        }
        if ($7_1 >>> 0 < $12_1 >>> 0) {
         break block4
        }
        block48 : {
         block47 : {
          if ((HEAP32[($7_1 + 16 | 0) >> 2] | 0 | 0) != ($8_1 | 0)) {
           break block47
          }
          HEAP32[($7_1 + 16 | 0) >> 2] = $0_1;
          break block48;
         }
         HEAP32[($7_1 + 20 | 0) >> 2] = $0_1;
        }
        if (!$0_1) {
         break block44
        }
       }
       if ($0_1 >>> 0 < $12_1 >>> 0) {
        break block4
       }
       HEAP32[($0_1 + 24 | 0) >> 2] = $7_1;
       block49 : {
        $6_1 = HEAP32[($8_1 + 16 | 0) >> 2] | 0;
        if (!$6_1) {
         break block49
        }
        if ($6_1 >>> 0 < $12_1 >>> 0) {
         break block4
        }
        HEAP32[($0_1 + 16 | 0) >> 2] = $6_1;
        HEAP32[($6_1 + 24 | 0) >> 2] = $0_1;
       }
       $6_1 = HEAP32[($8_1 + 20 | 0) >> 2] | 0;
       if (!$6_1) {
        break block44
       }
       if ($6_1 >>> 0 < $12_1 >>> 0) {
        break block4
       }
       HEAP32[($0_1 + 20 | 0) >> 2] = $6_1;
       HEAP32[($6_1 + 24 | 0) >> 2] = $0_1;
      }
      block51 : {
       block50 : {
        if ($4_1 >>> 0 > 15 >>> 0) {
         break block50
        }
        $0_1 = $4_1 + $3_1 | 0;
        HEAP32[($8_1 + 4 | 0) >> 2] = $0_1 | 3 | 0;
        $0_1 = $8_1 + $0_1 | 0;
        HEAP32[($0_1 + 4 | 0) >> 2] = HEAP32[($0_1 + 4 | 0) >> 2] | 0 | 1 | 0;
        break block51;
       }
       HEAP32[($8_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
       $5_1 = $8_1 + $3_1 | 0;
       HEAP32[($5_1 + 4 | 0) >> 2] = $4_1 | 1 | 0;
       HEAP32[($5_1 + $4_1 | 0) >> 2] = $4_1;
       block52 : {
        if ($4_1 >>> 0 > 255 >>> 0) {
         break block52
        }
        $0_1 = ($4_1 & 248 | 0) + 69936 | 0;
        block54 : {
         block53 : {
          $3_1 = HEAP32[(0 + 69896 | 0) >> 2] | 0;
          $4_1 = 1 << ($4_1 >>> 3 | 0) | 0;
          if ($3_1 & $4_1 | 0) {
           break block53
          }
          HEAP32[(0 + 69896 | 0) >> 2] = $3_1 | $4_1 | 0;
          $4_1 = $0_1;
          break block54;
         }
         $4_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
         if ($4_1 >>> 0 < $12_1 >>> 0) {
          break block4
         }
        }
        HEAP32[($0_1 + 8 | 0) >> 2] = $5_1;
        HEAP32[($4_1 + 12 | 0) >> 2] = $5_1;
        HEAP32[($5_1 + 12 | 0) >> 2] = $0_1;
        HEAP32[($5_1 + 8 | 0) >> 2] = $4_1;
        break block51;
       }
       $0_1 = 31;
       block55 : {
        if ($4_1 >>> 0 > 16777215 >>> 0) {
         break block55
        }
        $0_1 = Math_clz32($4_1 >>> 8 | 0);
        $0_1 = ((($4_1 >>> (38 - $0_1 | 0) | 0) & 1 | 0) - ($0_1 << 1 | 0) | 0) + 62 | 0;
       }
       HEAP32[($5_1 + 28 | 0) >> 2] = $0_1;
       i64toi32_i32$1 = $5_1;
       i64toi32_i32$0 = 0;
       HEAP32[($5_1 + 16 | 0) >> 2] = 0;
       HEAP32[($5_1 + 20 | 0) >> 2] = i64toi32_i32$0;
       $3_1 = ($0_1 << 2 | 0) + 70200 | 0;
       block58 : {
        block57 : {
         block56 : {
          $6_1 = 1 << $0_1 | 0;
          if ($11_1 & $6_1 | 0) {
           break block56
          }
          HEAP32[(0 + 69900 | 0) >> 2] = $11_1 | $6_1 | 0;
          HEAP32[$3_1 >> 2] = $5_1;
          HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
          break block57;
         }
         $0_1 = $4_1 << (($0_1 | 0) == (31 | 0) ? 0 : 25 - ($0_1 >>> 1 | 0) | 0) | 0;
         $6_1 = HEAP32[$3_1 >> 2] | 0;
         label5 : while (1) {
          $3_1 = $6_1;
          if (((HEAP32[($6_1 + 4 | 0) >> 2] | 0) & -8 | 0 | 0) == ($4_1 | 0)) {
           break block58
          }
          $6_1 = $0_1 >>> 29 | 0;
          $0_1 = $0_1 << 1 | 0;
          $2_1 = $3_1 + ($6_1 & 4 | 0) | 0;
          $6_1 = HEAP32[($2_1 + 16 | 0) >> 2] | 0;
          if ($6_1) {
           continue label5
          }
          break label5;
         };
         $0_1 = $2_1 + 16 | 0;
         if ($0_1 >>> 0 < $12_1 >>> 0) {
          break block4
         }
         HEAP32[$0_1 >> 2] = $5_1;
         HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
        }
        HEAP32[($5_1 + 12 | 0) >> 2] = $5_1;
        HEAP32[($5_1 + 8 | 0) >> 2] = $5_1;
        break block51;
       }
       if ($3_1 >>> 0 < $12_1 >>> 0) {
        break block4
       }
       $0_1 = HEAP32[($3_1 + 8 | 0) >> 2] | 0;
       if ($0_1 >>> 0 < $12_1 >>> 0) {
        break block4
       }
       HEAP32[($0_1 + 12 | 0) >> 2] = $5_1;
       HEAP32[($3_1 + 8 | 0) >> 2] = $5_1;
       HEAP32[($5_1 + 24 | 0) >> 2] = 0;
       HEAP32[($5_1 + 12 | 0) >> 2] = $3_1;
       HEAP32[($5_1 + 8 | 0) >> 2] = $0_1;
      }
      $0_1 = $8_1 + 8 | 0;
      break block5;
     }
     block59 : {
      $0_1 = HEAP32[(0 + 69904 | 0) >> 2] | 0;
      if ($0_1 >>> 0 < $3_1 >>> 0) {
       break block59
      }
      $4_1 = HEAP32[(0 + 69916 | 0) >> 2] | 0;
      block61 : {
       block60 : {
        $6_1 = $0_1 - $3_1 | 0;
        if ($6_1 >>> 0 < 16 >>> 0) {
         break block60
        }
        $5_1 = $4_1 + $3_1 | 0;
        HEAP32[($5_1 + 4 | 0) >> 2] = $6_1 | 1 | 0;
        HEAP32[($4_1 + $0_1 | 0) >> 2] = $6_1;
        HEAP32[($4_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
        break block61;
       }
       HEAP32[($4_1 + 4 | 0) >> 2] = $0_1 | 3 | 0;
       $0_1 = $4_1 + $0_1 | 0;
       HEAP32[($0_1 + 4 | 0) >> 2] = HEAP32[($0_1 + 4 | 0) >> 2] | 0 | 1 | 0;
       $5_1 = 0;
       $6_1 = 0;
      }
      HEAP32[(0 + 69904 | 0) >> 2] = $6_1;
      HEAP32[(0 + 69916 | 0) >> 2] = $5_1;
      $0_1 = $4_1 + 8 | 0;
      break block5;
     }
     block62 : {
      $5_1 = HEAP32[(0 + 69908 | 0) >> 2] | 0;
      if ($5_1 >>> 0 <= $3_1 >>> 0) {
       break block62
      }
      $4_1 = $5_1 - $3_1 | 0;
      HEAP32[(0 + 69908 | 0) >> 2] = $4_1;
      $0_1 = HEAP32[(0 + 69920 | 0) >> 2] | 0;
      $6_1 = $0_1 + $3_1 | 0;
      HEAP32[(0 + 69920 | 0) >> 2] = $6_1;
      HEAP32[($6_1 + 4 | 0) >> 2] = $4_1 | 1 | 0;
      HEAP32[($0_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
      $0_1 = $0_1 + 8 | 0;
      break block5;
     }
     block64 : {
      block63 : {
       if (!(HEAP32[(0 + 70368 | 0) >> 2] | 0)) {
        break block63
       }
       $4_1 = HEAP32[(0 + 70376 | 0) >> 2] | 0;
       break block64;
      }
      i64toi32_i32$1 = 0;
      i64toi32_i32$0 = -1;
      HEAP32[(i64toi32_i32$1 + 70380 | 0) >> 2] = -1;
      HEAP32[(i64toi32_i32$1 + 70384 | 0) >> 2] = i64toi32_i32$0;
      i64toi32_i32$1 = 0;
      i64toi32_i32$0 = 4096;
      HEAP32[(i64toi32_i32$1 + 70372 | 0) >> 2] = 4096;
      HEAP32[(i64toi32_i32$1 + 70376 | 0) >> 2] = i64toi32_i32$0;
      HEAP32[(0 + 70368 | 0) >> 2] = (($1_1 + 12 | 0) & -16 | 0) ^ 1431655768 | 0;
      HEAP32[(0 + 70388 | 0) >> 2] = 0;
      HEAP32[(0 + 70340 | 0) >> 2] = 0;
      $4_1 = 4096;
     }
     $0_1 = 0;
     $7_1 = $3_1 + 47 | 0;
     $2_1 = $4_1 + $7_1 | 0;
     $12_1 = 0 - $4_1 | 0;
     $8_1 = $2_1 & $12_1 | 0;
     if ($8_1 >>> 0 <= $3_1 >>> 0) {
      break block5
     }
     $0_1 = 0;
     block65 : {
      $4_1 = HEAP32[(0 + 70336 | 0) >> 2] | 0;
      if (!$4_1) {
       break block65
      }
      $6_1 = HEAP32[(0 + 70328 | 0) >> 2] | 0;
      $11_1 = $6_1 + $8_1 | 0;
      if ($11_1 >>> 0 <= $6_1 >>> 0) {
       break block5
      }
      if ($11_1 >>> 0 > $4_1 >>> 0) {
       break block5
      }
     }
     block77 : {
      block74 : {
       block66 : {
        if ((HEAPU8[(0 + 70340 | 0) >> 0] | 0) & 4 | 0) {
         break block66
        }
        block70 : {
         block75 : {
          block73 : {
           block69 : {
            block67 : {
             $4_1 = HEAP32[(0 + 69920 | 0) >> 2] | 0;
             if (!$4_1) {
              break block67
             }
             $0_1 = 70344;
             label6 : while (1) {
              block68 : {
               $6_1 = HEAP32[$0_1 >> 2] | 0;
               if ($4_1 >>> 0 < $6_1 >>> 0) {
                break block68
               }
               if ($4_1 >>> 0 < ($6_1 + (HEAP32[($0_1 + 4 | 0) >> 2] | 0) | 0) >>> 0) {
                break block69
               }
              }
              $0_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
              if ($0_1) {
               continue label6
              }
              break label6;
             };
            }
            $5_1 = $51(0 | 0) | 0;
            if (($5_1 | 0) == (-1 | 0)) {
             break block70
            }
            $2_1 = $8_1;
            block71 : {
             $0_1 = HEAP32[(0 + 70372 | 0) >> 2] | 0;
             $4_1 = $0_1 + -1 | 0;
             if (!($4_1 & $5_1 | 0)) {
              break block71
             }
             $2_1 = ($8_1 - $5_1 | 0) + (($4_1 + $5_1 | 0) & (0 - $0_1 | 0) | 0) | 0;
            }
            if ($2_1 >>> 0 <= $3_1 >>> 0) {
             break block70
            }
            block72 : {
             $0_1 = HEAP32[(0 + 70336 | 0) >> 2] | 0;
             if (!$0_1) {
              break block72
             }
             $4_1 = HEAP32[(0 + 70328 | 0) >> 2] | 0;
             $6_1 = $4_1 + $2_1 | 0;
             if ($6_1 >>> 0 <= $4_1 >>> 0) {
              break block70
             }
             if ($6_1 >>> 0 > $0_1 >>> 0) {
              break block70
             }
            }
            $0_1 = $51($2_1 | 0) | 0;
            if (($0_1 | 0) != ($5_1 | 0)) {
             break block73
            }
            break block74;
           }
           $2_1 = ($2_1 - $5_1 | 0) & $12_1 | 0;
           $5_1 = $51($2_1 | 0) | 0;
           if (($5_1 | 0) == ((HEAP32[$0_1 >> 2] | 0) + (HEAP32[($0_1 + 4 | 0) >> 2] | 0) | 0 | 0)) {
            break block75
           }
           $0_1 = $5_1;
          }
          if (($0_1 | 0) == (-1 | 0)) {
           break block70
          }
          block76 : {
           if ($2_1 >>> 0 < ($3_1 + 48 | 0) >>> 0) {
            break block76
           }
           $5_1 = $0_1;
           break block74;
          }
          $4_1 = HEAP32[(0 + 70376 | 0) >> 2] | 0;
          $4_1 = (($7_1 - $2_1 | 0) + $4_1 | 0) & (0 - $4_1 | 0) | 0;
          if (($51($4_1 | 0) | 0 | 0) == (-1 | 0)) {
           break block70
          }
          $2_1 = $4_1 + $2_1 | 0;
          $5_1 = $0_1;
          break block74;
         }
         if (($5_1 | 0) != (-1 | 0)) {
          break block74
         }
        }
        HEAP32[(0 + 70340 | 0) >> 2] = HEAP32[(0 + 70340 | 0) >> 2] | 0 | 4 | 0;
       }
       $5_1 = $51($8_1 | 0) | 0;
       $0_1 = $51(0 | 0) | 0;
       if (($5_1 | 0) == (-1 | 0)) {
        break block77
       }
       if (($0_1 | 0) == (-1 | 0)) {
        break block77
       }
       if ($5_1 >>> 0 >= $0_1 >>> 0) {
        break block77
       }
       $2_1 = $0_1 - $5_1 | 0;
       if ($2_1 >>> 0 <= ($3_1 + 40 | 0) >>> 0) {
        break block77
       }
      }
      $0_1 = (HEAP32[(0 + 70328 | 0) >> 2] | 0) + $2_1 | 0;
      HEAP32[(0 + 70328 | 0) >> 2] = $0_1;
      block78 : {
       if ($0_1 >>> 0 <= (HEAP32[(0 + 70332 | 0) >> 2] | 0) >>> 0) {
        break block78
       }
       HEAP32[(0 + 70332 | 0) >> 2] = $0_1;
      }
      block84 : {
       block81 : {
        block80 : {
         block79 : {
          $4_1 = HEAP32[(0 + 69920 | 0) >> 2] | 0;
          if (!$4_1) {
           break block79
          }
          $0_1 = 70344;
          label7 : while (1) {
           $6_1 = HEAP32[$0_1 >> 2] | 0;
           $8_1 = HEAP32[($0_1 + 4 | 0) >> 2] | 0;
           if (($5_1 | 0) == ($6_1 + $8_1 | 0 | 0)) {
            break block80
           }
           $0_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
           if ($0_1) {
            continue label7
           }
           break block81;
          };
         }
         block83 : {
          block82 : {
           $0_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
           if (!$0_1) {
            break block82
           }
           if ($5_1 >>> 0 >= $0_1 >>> 0) {
            break block83
           }
          }
          HEAP32[(0 + 69912 | 0) >> 2] = $5_1;
         }
         $0_1 = 0;
         HEAP32[(0 + 70348 | 0) >> 2] = $2_1;
         HEAP32[(0 + 70344 | 0) >> 2] = $5_1;
         HEAP32[(0 + 69928 | 0) >> 2] = -1;
         HEAP32[(0 + 69932 | 0) >> 2] = HEAP32[(0 + 70368 | 0) >> 2] | 0;
         HEAP32[(0 + 70356 | 0) >> 2] = 0;
         label8 : while (1) {
          $4_1 = $0_1 << 3 | 0;
          $6_1 = $4_1 + 69936 | 0;
          HEAP32[($4_1 + 69944 | 0) >> 2] = $6_1;
          HEAP32[($4_1 + 69948 | 0) >> 2] = $6_1;
          $0_1 = $0_1 + 1 | 0;
          if (($0_1 | 0) != (32 | 0)) {
           continue label8
          }
          break label8;
         };
         $0_1 = $2_1 + -40 | 0;
         $4_1 = (-8 - $5_1 | 0) & 7 | 0;
         $6_1 = $0_1 - $4_1 | 0;
         HEAP32[(0 + 69908 | 0) >> 2] = $6_1;
         $4_1 = $5_1 + $4_1 | 0;
         HEAP32[(0 + 69920 | 0) >> 2] = $4_1;
         HEAP32[($4_1 + 4 | 0) >> 2] = $6_1 | 1 | 0;
         HEAP32[(($5_1 + $0_1 | 0) + 4 | 0) >> 2] = 40;
         HEAP32[(0 + 69924 | 0) >> 2] = HEAP32[(0 + 70384 | 0) >> 2] | 0;
         break block84;
        }
        if ($4_1 >>> 0 >= $5_1 >>> 0) {
         break block81
        }
        if ($4_1 >>> 0 < $6_1 >>> 0) {
         break block81
        }
        if ((HEAP32[($0_1 + 12 | 0) >> 2] | 0) & 8 | 0) {
         break block81
        }
        HEAP32[($0_1 + 4 | 0) >> 2] = $8_1 + $2_1 | 0;
        $0_1 = (-8 - $4_1 | 0) & 7 | 0;
        $6_1 = $4_1 + $0_1 | 0;
        HEAP32[(0 + 69920 | 0) >> 2] = $6_1;
        $5_1 = (HEAP32[(0 + 69908 | 0) >> 2] | 0) + $2_1 | 0;
        $0_1 = $5_1 - $0_1 | 0;
        HEAP32[(0 + 69908 | 0) >> 2] = $0_1;
        HEAP32[($6_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
        HEAP32[(($4_1 + $5_1 | 0) + 4 | 0) >> 2] = 40;
        HEAP32[(0 + 69924 | 0) >> 2] = HEAP32[(0 + 70384 | 0) >> 2] | 0;
        break block84;
       }
       block85 : {
        if ($5_1 >>> 0 >= (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
         break block85
        }
        HEAP32[(0 + 69912 | 0) >> 2] = $5_1;
       }
       $6_1 = $5_1 + $2_1 | 0;
       $0_1 = 70344;
       block87 : {
        block86 : {
         label9 : while (1) {
          $8_1 = HEAP32[$0_1 >> 2] | 0;
          if (($8_1 | 0) == ($6_1 | 0)) {
           break block86
          }
          $0_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
          if ($0_1) {
           continue label9
          }
          break block87;
         };
        }
        if (!((HEAPU8[($0_1 + 12 | 0) >> 0] | 0) & 8 | 0)) {
         break block88
        }
       }
       $0_1 = 70344;
       block90 : {
        label10 : while (1) {
         block89 : {
          $6_1 = HEAP32[$0_1 >> 2] | 0;
          if ($4_1 >>> 0 < $6_1 >>> 0) {
           break block89
          }
          $6_1 = $6_1 + (HEAP32[($0_1 + 4 | 0) >> 2] | 0) | 0;
          if ($4_1 >>> 0 < $6_1 >>> 0) {
           break block90
          }
         }
         $0_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
         continue label10;
        };
       }
       $0_1 = $2_1 + -40 | 0;
       $8_1 = (-8 - $5_1 | 0) & 7 | 0;
       $12_1 = $0_1 - $8_1 | 0;
       HEAP32[(0 + 69908 | 0) >> 2] = $12_1;
       $8_1 = $5_1 + $8_1 | 0;
       HEAP32[(0 + 69920 | 0) >> 2] = $8_1;
       HEAP32[($8_1 + 4 | 0) >> 2] = $12_1 | 1 | 0;
       HEAP32[(($5_1 + $0_1 | 0) + 4 | 0) >> 2] = 40;
       HEAP32[(0 + 69924 | 0) >> 2] = HEAP32[(0 + 70384 | 0) >> 2] | 0;
       $0_1 = ($6_1 + ((39 - $6_1 | 0) & 7 | 0) | 0) + -47 | 0;
       $8_1 = $0_1 >>> 0 < ($4_1 + 16 | 0) >>> 0 ? $4_1 : $0_1;
       HEAP32[($8_1 + 4 | 0) >> 2] = 27;
       i64toi32_i32$2 = 0;
       i64toi32_i32$0 = HEAP32[(i64toi32_i32$2 + 70352 | 0) >> 2] | 0;
       i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 70356 | 0) >> 2] | 0;
       $1142 = i64toi32_i32$0;
       i64toi32_i32$0 = $8_1;
       HEAP32[($8_1 + 16 | 0) >> 2] = $1142;
       HEAP32[($8_1 + 20 | 0) >> 2] = i64toi32_i32$1;
       i64toi32_i32$2 = 0;
       i64toi32_i32$1 = HEAP32[(i64toi32_i32$2 + 70344 | 0) >> 2] | 0;
       i64toi32_i32$0 = HEAP32[(i64toi32_i32$2 + 70348 | 0) >> 2] | 0;
       $1144 = i64toi32_i32$1;
       i64toi32_i32$1 = $8_1;
       HEAP32[($8_1 + 8 | 0) >> 2] = $1144;
       HEAP32[($8_1 + 12 | 0) >> 2] = i64toi32_i32$0;
       HEAP32[(0 + 70352 | 0) >> 2] = $8_1 + 8 | 0;
       HEAP32[(0 + 70348 | 0) >> 2] = $2_1;
       HEAP32[(0 + 70344 | 0) >> 2] = $5_1;
       HEAP32[(0 + 70356 | 0) >> 2] = 0;
       $5_1 = $8_1 + 24 | 0;
       label11 : while (1) {
        $0_1 = $5_1;
        HEAP32[($0_1 + 4 | 0) >> 2] = 7;
        $5_1 = $0_1 + 4 | 0;
        if (($0_1 + 8 | 0) >>> 0 < $6_1 >>> 0) {
         continue label11
        }
        break label11;
       };
       if (($8_1 | 0) == ($4_1 | 0)) {
        break block84
       }
       HEAP32[($8_1 + 4 | 0) >> 2] = (HEAP32[($8_1 + 4 | 0) >> 2] | 0) & -2 | 0;
       $5_1 = $8_1 - $4_1 | 0;
       HEAP32[($4_1 + 4 | 0) >> 2] = $5_1 | 1 | 0;
       HEAP32[$8_1 >> 2] = $5_1;
       block94 : {
        block91 : {
         if ($5_1 >>> 0 > 255 >>> 0) {
          break block91
         }
         $0_1 = ($5_1 & 248 | 0) + 69936 | 0;
         block93 : {
          block92 : {
           $6_1 = HEAP32[(0 + 69896 | 0) >> 2] | 0;
           $5_1 = 1 << ($5_1 >>> 3 | 0) | 0;
           if ($6_1 & $5_1 | 0) {
            break block92
           }
           HEAP32[(0 + 69896 | 0) >> 2] = $6_1 | $5_1 | 0;
           $6_1 = $0_1;
           break block93;
          }
          $6_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
          if ($6_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
           break block4
          }
         }
         HEAP32[($0_1 + 8 | 0) >> 2] = $4_1;
         HEAP32[($6_1 + 12 | 0) >> 2] = $4_1;
         $5_1 = 12;
         $8_1 = 8;
         break block94;
        }
        $0_1 = 31;
        block95 : {
         if ($5_1 >>> 0 > 16777215 >>> 0) {
          break block95
         }
         $0_1 = Math_clz32($5_1 >>> 8 | 0);
         $0_1 = ((($5_1 >>> (38 - $0_1 | 0) | 0) & 1 | 0) - ($0_1 << 1 | 0) | 0) + 62 | 0;
        }
        HEAP32[($4_1 + 28 | 0) >> 2] = $0_1;
        i64toi32_i32$1 = $4_1;
        i64toi32_i32$0 = 0;
        HEAP32[($4_1 + 16 | 0) >> 2] = 0;
        HEAP32[($4_1 + 20 | 0) >> 2] = i64toi32_i32$0;
        $6_1 = ($0_1 << 2 | 0) + 70200 | 0;
        block98 : {
         block97 : {
          block96 : {
           $8_1 = HEAP32[(0 + 69900 | 0) >> 2] | 0;
           $2_1 = 1 << $0_1 | 0;
           if ($8_1 & $2_1 | 0) {
            break block96
           }
           HEAP32[(0 + 69900 | 0) >> 2] = $8_1 | $2_1 | 0;
           HEAP32[$6_1 >> 2] = $4_1;
           HEAP32[($4_1 + 24 | 0) >> 2] = $6_1;
           break block97;
          }
          $0_1 = $5_1 << (($0_1 | 0) == (31 | 0) ? 0 : 25 - ($0_1 >>> 1 | 0) | 0) | 0;
          $8_1 = HEAP32[$6_1 >> 2] | 0;
          label12 : while (1) {
           $6_1 = $8_1;
           if (((HEAP32[($6_1 + 4 | 0) >> 2] | 0) & -8 | 0 | 0) == ($5_1 | 0)) {
            break block98
           }
           $8_1 = $0_1 >>> 29 | 0;
           $0_1 = $0_1 << 1 | 0;
           $2_1 = $6_1 + ($8_1 & 4 | 0) | 0;
           $8_1 = HEAP32[($2_1 + 16 | 0) >> 2] | 0;
           if ($8_1) {
            continue label12
           }
           break label12;
          };
          $0_1 = $2_1 + 16 | 0;
          if ($0_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
           break block4
          }
          HEAP32[$0_1 >> 2] = $4_1;
          HEAP32[($4_1 + 24 | 0) >> 2] = $6_1;
         }
         $5_1 = 8;
         $8_1 = 12;
         $6_1 = $4_1;
         $0_1 = $6_1;
         break block94;
        }
        $5_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
        if ($6_1 >>> 0 < $5_1 >>> 0) {
         break block4
        }
        $0_1 = HEAP32[($6_1 + 8 | 0) >> 2] | 0;
        if ($0_1 >>> 0 < $5_1 >>> 0) {
         break block4
        }
        HEAP32[($0_1 + 12 | 0) >> 2] = $4_1;
        HEAP32[($6_1 + 8 | 0) >> 2] = $4_1;
        HEAP32[($4_1 + 8 | 0) >> 2] = $0_1;
        $0_1 = 0;
        $5_1 = 24;
        $8_1 = 12;
       }
       HEAP32[($4_1 + $8_1 | 0) >> 2] = $6_1;
       HEAP32[($4_1 + $5_1 | 0) >> 2] = $0_1;
      }
      $0_1 = HEAP32[(0 + 69908 | 0) >> 2] | 0;
      if ($0_1 >>> 0 <= $3_1 >>> 0) {
       break block77
      }
      $4_1 = $0_1 - $3_1 | 0;
      HEAP32[(0 + 69908 | 0) >> 2] = $4_1;
      $0_1 = HEAP32[(0 + 69920 | 0) >> 2] | 0;
      $6_1 = $0_1 + $3_1 | 0;
      HEAP32[(0 + 69920 | 0) >> 2] = $6_1;
      HEAP32[($6_1 + 4 | 0) >> 2] = $4_1 | 1 | 0;
      HEAP32[($0_1 + 4 | 0) >> 2] = $3_1 | 3 | 0;
      $0_1 = $0_1 + 8 | 0;
      break block5;
     }
     (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = 48), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
     $0_1 = 0;
     break block5;
    }
    $42();
    wasm2js_trap();
   }
   HEAP32[$0_1 >> 2] = $5_1;
   HEAP32[($0_1 + 4 | 0) >> 2] = (HEAP32[($0_1 + 4 | 0) >> 2] | 0) + $2_1 | 0;
   $0_1 = $48($5_1 | 0, $8_1 | 0, $3_1 | 0) | 0;
  }
  global$0 = $1_1 + 16 | 0;
  return $0_1 | 0;
 }
 
 function $48($0_1, $1_1, $2_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  var $4_1 = 0, $5_1 = 0, $7_1 = 0, $6_1 = 0, $8_1 = 0, $3_1 = 0, $9_1 = 0, $352 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  $3_1 = $0_1 + ((-8 - $0_1 | 0) & 7 | 0) | 0;
  HEAP32[($3_1 + 4 | 0) >> 2] = $2_1 | 3 | 0;
  $4_1 = $1_1 + ((-8 - $1_1 | 0) & 7 | 0) | 0;
  $5_1 = $3_1 + $2_1 | 0;
  $0_1 = $4_1 - $5_1 | 0;
  block6 : {
   block1 : {
    block : {
     if (($4_1 | 0) != (HEAP32[(0 + 69920 | 0) >> 2] | 0 | 0)) {
      break block
     }
     HEAP32[(0 + 69920 | 0) >> 2] = $5_1;
     $2_1 = (HEAP32[(0 + 69908 | 0) >> 2] | 0) + $0_1 | 0;
     HEAP32[(0 + 69908 | 0) >> 2] = $2_1;
     HEAP32[($5_1 + 4 | 0) >> 2] = $2_1 | 1 | 0;
     break block1;
    }
    block2 : {
     if (($4_1 | 0) != (HEAP32[(0 + 69916 | 0) >> 2] | 0 | 0)) {
      break block2
     }
     HEAP32[(0 + 69916 | 0) >> 2] = $5_1;
     $2_1 = (HEAP32[(0 + 69904 | 0) >> 2] | 0) + $0_1 | 0;
     HEAP32[(0 + 69904 | 0) >> 2] = $2_1;
     HEAP32[($5_1 + 4 | 0) >> 2] = $2_1 | 1 | 0;
     HEAP32[($5_1 + $2_1 | 0) >> 2] = $2_1;
     break block1;
    }
    block3 : {
     $6_1 = HEAP32[($4_1 + 4 | 0) >> 2] | 0;
     if (($6_1 & 3 | 0 | 0) != (1 | 0)) {
      break block3
     }
     $2_1 = HEAP32[($4_1 + 12 | 0) >> 2] | 0;
     block8 : {
      block4 : {
       if ($6_1 >>> 0 > 255 >>> 0) {
        break block4
       }
       block5 : {
        $1_1 = HEAP32[($4_1 + 8 | 0) >> 2] | 0;
        $7_1 = ($6_1 & 248 | 0) + 69936 | 0;
        if (($1_1 | 0) == ($7_1 | 0)) {
         break block5
        }
        if ($1_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
         break block6
        }
        if ((HEAP32[($1_1 + 12 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
         break block6
        }
       }
       block7 : {
        if (($2_1 | 0) != ($1_1 | 0)) {
         break block7
        }
        (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69896 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $6_1 >>> 3 | 0 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69896 | 0) >> 2] = wasm2js_i32$1;
        break block8;
       }
       block9 : {
        if (($2_1 | 0) == ($7_1 | 0)) {
         break block9
        }
        if ($2_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
         break block6
        }
        if ((HEAP32[($2_1 + 8 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
         break block6
        }
       }
       HEAP32[($1_1 + 12 | 0) >> 2] = $2_1;
       HEAP32[($2_1 + 8 | 0) >> 2] = $1_1;
       break block8;
      }
      $8_1 = HEAP32[($4_1 + 24 | 0) >> 2] | 0;
      block11 : {
       block10 : {
        if (($2_1 | 0) == ($4_1 | 0)) {
         break block10
        }
        $1_1 = HEAP32[($4_1 + 8 | 0) >> 2] | 0;
        if ($1_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
         break block6
        }
        if ((HEAP32[($1_1 + 12 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
         break block6
        }
        if ((HEAP32[($2_1 + 8 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
         break block6
        }
        HEAP32[($1_1 + 12 | 0) >> 2] = $2_1;
        HEAP32[($2_1 + 8 | 0) >> 2] = $1_1;
        break block11;
       }
       block14 : {
        block13 : {
         block12 : {
          $1_1 = HEAP32[($4_1 + 20 | 0) >> 2] | 0;
          if (!$1_1) {
           break block12
          }
          $7_1 = $4_1 + 20 | 0;
          break block13;
         }
         $1_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
         if (!$1_1) {
          break block14
         }
         $7_1 = $4_1 + 16 | 0;
        }
        label : while (1) {
         $9_1 = $7_1;
         $2_1 = $1_1;
         $7_1 = $2_1 + 20 | 0;
         $1_1 = HEAP32[($2_1 + 20 | 0) >> 2] | 0;
         if ($1_1) {
          continue label
         }
         $7_1 = $2_1 + 16 | 0;
         $1_1 = HEAP32[($2_1 + 16 | 0) >> 2] | 0;
         if ($1_1) {
          continue label
         }
         break label;
        };
        if ($9_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
         break block6
        }
        HEAP32[$9_1 >> 2] = 0;
        break block11;
       }
       $2_1 = 0;
      }
      if (!$8_1) {
       break block8
      }
      block16 : {
       block15 : {
        $7_1 = HEAP32[($4_1 + 28 | 0) >> 2] | 0;
        $1_1 = $7_1 << 2 | 0;
        if (($4_1 | 0) != (HEAP32[($1_1 + 70200 | 0) >> 2] | 0 | 0)) {
         break block15
        }
        HEAP32[($1_1 + 70200 | 0) >> 2] = $2_1;
        if ($2_1) {
         break block16
        }
        (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69900 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $7_1 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69900 | 0) >> 2] = wasm2js_i32$1;
        break block8;
       }
       if ($8_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
        break block6
       }
       block18 : {
        block17 : {
         if ((HEAP32[($8_1 + 16 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block17
         }
         HEAP32[($8_1 + 16 | 0) >> 2] = $2_1;
         break block18;
        }
        HEAP32[($8_1 + 20 | 0) >> 2] = $2_1;
       }
       if (!$2_1) {
        break block8
       }
      }
      $7_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
      if ($2_1 >>> 0 < $7_1 >>> 0) {
       break block6
      }
      HEAP32[($2_1 + 24 | 0) >> 2] = $8_1;
      block19 : {
       $1_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
       if (!$1_1) {
        break block19
       }
       if ($1_1 >>> 0 < $7_1 >>> 0) {
        break block6
       }
       HEAP32[($2_1 + 16 | 0) >> 2] = $1_1;
       HEAP32[($1_1 + 24 | 0) >> 2] = $2_1;
      }
      $1_1 = HEAP32[($4_1 + 20 | 0) >> 2] | 0;
      if (!$1_1) {
       break block8
      }
      if ($1_1 >>> 0 < $7_1 >>> 0) {
       break block6
      }
      HEAP32[($2_1 + 20 | 0) >> 2] = $1_1;
      HEAP32[($1_1 + 24 | 0) >> 2] = $2_1;
     }
     $2_1 = $6_1 & -8 | 0;
     $0_1 = $2_1 + $0_1 | 0;
     $4_1 = $4_1 + $2_1 | 0;
     $6_1 = HEAP32[($4_1 + 4 | 0) >> 2] | 0;
    }
    HEAP32[($4_1 + 4 | 0) >> 2] = $6_1 & -2 | 0;
    HEAP32[($5_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
    HEAP32[($5_1 + $0_1 | 0) >> 2] = $0_1;
    block20 : {
     if ($0_1 >>> 0 > 255 >>> 0) {
      break block20
     }
     $2_1 = ($0_1 & 248 | 0) + 69936 | 0;
     block22 : {
      block21 : {
       $1_1 = HEAP32[(0 + 69896 | 0) >> 2] | 0;
       $0_1 = 1 << ($0_1 >>> 3 | 0) | 0;
       if ($1_1 & $0_1 | 0) {
        break block21
       }
       HEAP32[(0 + 69896 | 0) >> 2] = $1_1 | $0_1 | 0;
       $0_1 = $2_1;
       break block22;
      }
      $0_1 = HEAP32[($2_1 + 8 | 0) >> 2] | 0;
      if ($0_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
       break block6
      }
     }
     HEAP32[($2_1 + 8 | 0) >> 2] = $5_1;
     HEAP32[($0_1 + 12 | 0) >> 2] = $5_1;
     HEAP32[($5_1 + 12 | 0) >> 2] = $2_1;
     HEAP32[($5_1 + 8 | 0) >> 2] = $0_1;
     break block1;
    }
    $2_1 = 31;
    block23 : {
     if ($0_1 >>> 0 > 16777215 >>> 0) {
      break block23
     }
     $2_1 = Math_clz32($0_1 >>> 8 | 0);
     $2_1 = ((($0_1 >>> (38 - $2_1 | 0) | 0) & 1 | 0) - ($2_1 << 1 | 0) | 0) + 62 | 0;
    }
    HEAP32[($5_1 + 28 | 0) >> 2] = $2_1;
    HEAP32[($5_1 + 16 | 0) >> 2] = 0;
    HEAP32[($5_1 + 20 | 0) >> 2] = 0;
    $1_1 = ($2_1 << 2 | 0) + 70200 | 0;
    block26 : {
     block25 : {
      block24 : {
       $7_1 = HEAP32[(0 + 69900 | 0) >> 2] | 0;
       $4_1 = 1 << $2_1 | 0;
       if ($7_1 & $4_1 | 0) {
        break block24
       }
       HEAP32[(0 + 69900 | 0) >> 2] = $7_1 | $4_1 | 0;
       HEAP32[$1_1 >> 2] = $5_1;
       HEAP32[($5_1 + 24 | 0) >> 2] = $1_1;
       break block25;
      }
      $2_1 = $0_1 << (($2_1 | 0) == (31 | 0) ? 0 : 25 - ($2_1 >>> 1 | 0) | 0) | 0;
      $7_1 = HEAP32[$1_1 >> 2] | 0;
      label1 : while (1) {
       $1_1 = $7_1;
       if (((HEAP32[($1_1 + 4 | 0) >> 2] | 0) & -8 | 0 | 0) == ($0_1 | 0)) {
        break block26
       }
       $7_1 = $2_1 >>> 29 | 0;
       $2_1 = $2_1 << 1 | 0;
       $4_1 = $1_1 + ($7_1 & 4 | 0) | 0;
       $7_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
       if ($7_1) {
        continue label1
       }
       break label1;
      };
      $2_1 = $4_1 + 16 | 0;
      if ($2_1 >>> 0 < (HEAP32[(0 + 69912 | 0) >> 2] | 0) >>> 0) {
       break block6
      }
      HEAP32[$2_1 >> 2] = $5_1;
      HEAP32[($5_1 + 24 | 0) >> 2] = $1_1;
     }
     HEAP32[($5_1 + 12 | 0) >> 2] = $5_1;
     HEAP32[($5_1 + 8 | 0) >> 2] = $5_1;
     break block1;
    }
    $0_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
    if ($1_1 >>> 0 < $0_1 >>> 0) {
     break block6
    }
    $2_1 = HEAP32[($1_1 + 8 | 0) >> 2] | 0;
    if ($2_1 >>> 0 < $0_1 >>> 0) {
     break block6
    }
    HEAP32[($2_1 + 12 | 0) >> 2] = $5_1;
    HEAP32[($1_1 + 8 | 0) >> 2] = $5_1;
    HEAP32[($5_1 + 24 | 0) >> 2] = 0;
    HEAP32[($5_1 + 12 | 0) >> 2] = $1_1;
    HEAP32[($5_1 + 8 | 0) >> 2] = $2_1;
   }
   return $3_1 + 8 | 0 | 0;
  }
  $42();
  wasm2js_trap();
 }
 
 function $49($0_1) {
  $0_1 = $0_1 | 0;
  var $3_1 = 0, $5_1 = 0, $1_1 = 0, $6_1 = 0, $4_1 = 0, $2_1 = 0, $7_1 = 0, $8_1 = 0, $10_1 = 0, $9_1 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  block1 : {
   block : {
    if (!$0_1) {
     break block
    }
    $1_1 = $0_1 + -8 | 0;
    $2_1 = HEAP32[(0 + 69912 | 0) >> 2] | 0;
    if ($1_1 >>> 0 < $2_1 >>> 0) {
     break block1
    }
    $3_1 = HEAP32[($0_1 + -4 | 0) >> 2] | 0;
    if (($3_1 & 3 | 0 | 0) == (1 | 0)) {
     break block1
    }
    $0_1 = $3_1 & -8 | 0;
    $4_1 = $1_1 + $0_1 | 0;
    block2 : {
     if ($3_1 & 1 | 0) {
      break block2
     }
     if (!($3_1 & 2 | 0)) {
      break block
     }
     $5_1 = HEAP32[$1_1 >> 2] | 0;
     $1_1 = $1_1 - $5_1 | 0;
     if ($1_1 >>> 0 < $2_1 >>> 0) {
      break block1
     }
     $0_1 = $5_1 + $0_1 | 0;
     block3 : {
      if (($1_1 | 0) == (HEAP32[(0 + 69916 | 0) >> 2] | 0 | 0)) {
       break block3
      }
      $3_1 = HEAP32[($1_1 + 12 | 0) >> 2] | 0;
      block4 : {
       if ($5_1 >>> 0 > 255 >>> 0) {
        break block4
       }
       block5 : {
        $6_1 = HEAP32[($1_1 + 8 | 0) >> 2] | 0;
        $7_1 = ($5_1 & 248 | 0) + 69936 | 0;
        if (($6_1 | 0) == ($7_1 | 0)) {
         break block5
        }
        if ($6_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        if ((HEAP32[($6_1 + 12 | 0) >> 2] | 0 | 0) != ($1_1 | 0)) {
         break block1
        }
       }
       block6 : {
        if (($3_1 | 0) != ($6_1 | 0)) {
         break block6
        }
        (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69896 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $5_1 >>> 3 | 0 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69896 | 0) >> 2] = wasm2js_i32$1;
        break block2;
       }
       block7 : {
        if (($3_1 | 0) == ($7_1 | 0)) {
         break block7
        }
        if ($3_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        if ((HEAP32[($3_1 + 8 | 0) >> 2] | 0 | 0) != ($1_1 | 0)) {
         break block1
        }
       }
       HEAP32[($6_1 + 12 | 0) >> 2] = $3_1;
       HEAP32[($3_1 + 8 | 0) >> 2] = $6_1;
       break block2;
      }
      $8_1 = HEAP32[($1_1 + 24 | 0) >> 2] | 0;
      block9 : {
       block8 : {
        if (($3_1 | 0) == ($1_1 | 0)) {
         break block8
        }
        $5_1 = HEAP32[($1_1 + 8 | 0) >> 2] | 0;
        if ($5_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        if ((HEAP32[($5_1 + 12 | 0) >> 2] | 0 | 0) != ($1_1 | 0)) {
         break block1
        }
        if ((HEAP32[($3_1 + 8 | 0) >> 2] | 0 | 0) != ($1_1 | 0)) {
         break block1
        }
        HEAP32[($5_1 + 12 | 0) >> 2] = $3_1;
        HEAP32[($3_1 + 8 | 0) >> 2] = $5_1;
        break block9;
       }
       block12 : {
        block11 : {
         block10 : {
          $5_1 = HEAP32[($1_1 + 20 | 0) >> 2] | 0;
          if (!$5_1) {
           break block10
          }
          $6_1 = $1_1 + 20 | 0;
          break block11;
         }
         $5_1 = HEAP32[($1_1 + 16 | 0) >> 2] | 0;
         if (!$5_1) {
          break block12
         }
         $6_1 = $1_1 + 16 | 0;
        }
        label : while (1) {
         $7_1 = $6_1;
         $3_1 = $5_1;
         $6_1 = $3_1 + 20 | 0;
         $5_1 = HEAP32[($3_1 + 20 | 0) >> 2] | 0;
         if ($5_1) {
          continue label
         }
         $6_1 = $3_1 + 16 | 0;
         $5_1 = HEAP32[($3_1 + 16 | 0) >> 2] | 0;
         if ($5_1) {
          continue label
         }
         break label;
        };
        if ($7_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        HEAP32[$7_1 >> 2] = 0;
        break block9;
       }
       $3_1 = 0;
      }
      if (!$8_1) {
       break block2
      }
      block14 : {
       block13 : {
        $6_1 = HEAP32[($1_1 + 28 | 0) >> 2] | 0;
        $5_1 = $6_1 << 2 | 0;
        if (($1_1 | 0) != (HEAP32[($5_1 + 70200 | 0) >> 2] | 0 | 0)) {
         break block13
        }
        HEAP32[($5_1 + 70200 | 0) >> 2] = $3_1;
        if ($3_1) {
         break block14
        }
        (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69900 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $6_1 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69900 | 0) >> 2] = wasm2js_i32$1;
        break block2;
       }
       if ($8_1 >>> 0 < $2_1 >>> 0) {
        break block1
       }
       block16 : {
        block15 : {
         if ((HEAP32[($8_1 + 16 | 0) >> 2] | 0 | 0) != ($1_1 | 0)) {
          break block15
         }
         HEAP32[($8_1 + 16 | 0) >> 2] = $3_1;
         break block16;
        }
        HEAP32[($8_1 + 20 | 0) >> 2] = $3_1;
       }
       if (!$3_1) {
        break block2
       }
      }
      if ($3_1 >>> 0 < $2_1 >>> 0) {
       break block1
      }
      HEAP32[($3_1 + 24 | 0) >> 2] = $8_1;
      block17 : {
       $5_1 = HEAP32[($1_1 + 16 | 0) >> 2] | 0;
       if (!$5_1) {
        break block17
       }
       if ($5_1 >>> 0 < $2_1 >>> 0) {
        break block1
       }
       HEAP32[($3_1 + 16 | 0) >> 2] = $5_1;
       HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
      }
      $5_1 = HEAP32[($1_1 + 20 | 0) >> 2] | 0;
      if (!$5_1) {
       break block2
      }
      if ($5_1 >>> 0 < $2_1 >>> 0) {
       break block1
      }
      HEAP32[($3_1 + 20 | 0) >> 2] = $5_1;
      HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
      break block2;
     }
     $3_1 = HEAP32[($4_1 + 4 | 0) >> 2] | 0;
     if (($3_1 & 3 | 0 | 0) != (3 | 0)) {
      break block2
     }
     HEAP32[(0 + 69904 | 0) >> 2] = $0_1;
     HEAP32[($4_1 + 4 | 0) >> 2] = $3_1 & -2 | 0;
     HEAP32[($1_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
     HEAP32[$4_1 >> 2] = $0_1;
     return;
    }
    if ($1_1 >>> 0 >= $4_1 >>> 0) {
     break block1
    }
    $7_1 = HEAP32[($4_1 + 4 | 0) >> 2] | 0;
    if (!($7_1 & 1 | 0)) {
     break block1
    }
    block36 : {
     block18 : {
      if ($7_1 & 2 | 0) {
       break block18
      }
      block19 : {
       if (($4_1 | 0) != (HEAP32[(0 + 69920 | 0) >> 2] | 0 | 0)) {
        break block19
       }
       HEAP32[(0 + 69920 | 0) >> 2] = $1_1;
       $0_1 = (HEAP32[(0 + 69908 | 0) >> 2] | 0) + $0_1 | 0;
       HEAP32[(0 + 69908 | 0) >> 2] = $0_1;
       HEAP32[($1_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
       if (($1_1 | 0) != (HEAP32[(0 + 69916 | 0) >> 2] | 0 | 0)) {
        break block
       }
       HEAP32[(0 + 69904 | 0) >> 2] = 0;
       HEAP32[(0 + 69916 | 0) >> 2] = 0;
       return;
      }
      block20 : {
       $9_1 = HEAP32[(0 + 69916 | 0) >> 2] | 0;
       if (($4_1 | 0) != ($9_1 | 0)) {
        break block20
       }
       HEAP32[(0 + 69916 | 0) >> 2] = $1_1;
       $0_1 = (HEAP32[(0 + 69904 | 0) >> 2] | 0) + $0_1 | 0;
       HEAP32[(0 + 69904 | 0) >> 2] = $0_1;
       HEAP32[($1_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
       HEAP32[($1_1 + $0_1 | 0) >> 2] = $0_1;
       return;
      }
      $3_1 = HEAP32[($4_1 + 12 | 0) >> 2] | 0;
      block24 : {
       block21 : {
        if ($7_1 >>> 0 > 255 >>> 0) {
         break block21
        }
        block22 : {
         $5_1 = HEAP32[($4_1 + 8 | 0) >> 2] | 0;
         $6_1 = ($7_1 & 248 | 0) + 69936 | 0;
         if (($5_1 | 0) == ($6_1 | 0)) {
          break block22
         }
         if ($5_1 >>> 0 < $2_1 >>> 0) {
          break block1
         }
         if ((HEAP32[($5_1 + 12 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block1
         }
        }
        block23 : {
         if (($3_1 | 0) != ($5_1 | 0)) {
          break block23
         }
         (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69896 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $7_1 >>> 3 | 0 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69896 | 0) >> 2] = wasm2js_i32$1;
         break block24;
        }
        block25 : {
         if (($3_1 | 0) == ($6_1 | 0)) {
          break block25
         }
         if ($3_1 >>> 0 < $2_1 >>> 0) {
          break block1
         }
         if ((HEAP32[($3_1 + 8 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block1
         }
        }
        HEAP32[($5_1 + 12 | 0) >> 2] = $3_1;
        HEAP32[($3_1 + 8 | 0) >> 2] = $5_1;
        break block24;
       }
       $10_1 = HEAP32[($4_1 + 24 | 0) >> 2] | 0;
       block27 : {
        block26 : {
         if (($3_1 | 0) == ($4_1 | 0)) {
          break block26
         }
         $5_1 = HEAP32[($4_1 + 8 | 0) >> 2] | 0;
         if ($5_1 >>> 0 < $2_1 >>> 0) {
          break block1
         }
         if ((HEAP32[($5_1 + 12 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block1
         }
         if ((HEAP32[($3_1 + 8 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
          break block1
         }
         HEAP32[($5_1 + 12 | 0) >> 2] = $3_1;
         HEAP32[($3_1 + 8 | 0) >> 2] = $5_1;
         break block27;
        }
        block30 : {
         block29 : {
          block28 : {
           $5_1 = HEAP32[($4_1 + 20 | 0) >> 2] | 0;
           if (!$5_1) {
            break block28
           }
           $6_1 = $4_1 + 20 | 0;
           break block29;
          }
          $5_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
          if (!$5_1) {
           break block30
          }
          $6_1 = $4_1 + 16 | 0;
         }
         label1 : while (1) {
          $8_1 = $6_1;
          $3_1 = $5_1;
          $6_1 = $3_1 + 20 | 0;
          $5_1 = HEAP32[($3_1 + 20 | 0) >> 2] | 0;
          if ($5_1) {
           continue label1
          }
          $6_1 = $3_1 + 16 | 0;
          $5_1 = HEAP32[($3_1 + 16 | 0) >> 2] | 0;
          if ($5_1) {
           continue label1
          }
          break label1;
         };
         if ($8_1 >>> 0 < $2_1 >>> 0) {
          break block1
         }
         HEAP32[$8_1 >> 2] = 0;
         break block27;
        }
        $3_1 = 0;
       }
       if (!$10_1) {
        break block24
       }
       block32 : {
        block31 : {
         $6_1 = HEAP32[($4_1 + 28 | 0) >> 2] | 0;
         $5_1 = $6_1 << 2 | 0;
         if (($4_1 | 0) != (HEAP32[($5_1 + 70200 | 0) >> 2] | 0 | 0)) {
          break block31
         }
         HEAP32[($5_1 + 70200 | 0) >> 2] = $3_1;
         if ($3_1) {
          break block32
         }
         (wasm2js_i32$0 = 0, wasm2js_i32$1 = (HEAP32[(0 + 69900 | 0) >> 2] | 0) & (__wasm_rotl_i32(-2 | 0, $6_1 | 0) | 0) | 0), HEAP32[(wasm2js_i32$0 + 69900 | 0) >> 2] = wasm2js_i32$1;
         break block24;
        }
        if ($10_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        block34 : {
         block33 : {
          if ((HEAP32[($10_1 + 16 | 0) >> 2] | 0 | 0) != ($4_1 | 0)) {
           break block33
          }
          HEAP32[($10_1 + 16 | 0) >> 2] = $3_1;
          break block34;
         }
         HEAP32[($10_1 + 20 | 0) >> 2] = $3_1;
        }
        if (!$3_1) {
         break block24
        }
       }
       if ($3_1 >>> 0 < $2_1 >>> 0) {
        break block1
       }
       HEAP32[($3_1 + 24 | 0) >> 2] = $10_1;
       block35 : {
        $5_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
        if (!$5_1) {
         break block35
        }
        if ($5_1 >>> 0 < $2_1 >>> 0) {
         break block1
        }
        HEAP32[($3_1 + 16 | 0) >> 2] = $5_1;
        HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
       }
       $5_1 = HEAP32[($4_1 + 20 | 0) >> 2] | 0;
       if (!$5_1) {
        break block24
       }
       if ($5_1 >>> 0 < $2_1 >>> 0) {
        break block1
       }
       HEAP32[($3_1 + 20 | 0) >> 2] = $5_1;
       HEAP32[($5_1 + 24 | 0) >> 2] = $3_1;
      }
      $0_1 = ($7_1 & -8 | 0) + $0_1 | 0;
      HEAP32[($1_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
      HEAP32[($1_1 + $0_1 | 0) >> 2] = $0_1;
      if (($1_1 | 0) != ($9_1 | 0)) {
       break block36
      }
      HEAP32[(0 + 69904 | 0) >> 2] = $0_1;
      return;
     }
     HEAP32[($4_1 + 4 | 0) >> 2] = $7_1 & -2 | 0;
     HEAP32[($1_1 + 4 | 0) >> 2] = $0_1 | 1 | 0;
     HEAP32[($1_1 + $0_1 | 0) >> 2] = $0_1;
    }
    block37 : {
     if ($0_1 >>> 0 > 255 >>> 0) {
      break block37
     }
     $3_1 = ($0_1 & 248 | 0) + 69936 | 0;
     block39 : {
      block38 : {
       $5_1 = HEAP32[(0 + 69896 | 0) >> 2] | 0;
       $0_1 = 1 << ($0_1 >>> 3 | 0) | 0;
       if ($5_1 & $0_1 | 0) {
        break block38
       }
       HEAP32[(0 + 69896 | 0) >> 2] = $5_1 | $0_1 | 0;
       $0_1 = $3_1;
       break block39;
      }
      $0_1 = HEAP32[($3_1 + 8 | 0) >> 2] | 0;
      if ($0_1 >>> 0 < $2_1 >>> 0) {
       break block1
      }
     }
     HEAP32[($3_1 + 8 | 0) >> 2] = $1_1;
     HEAP32[($0_1 + 12 | 0) >> 2] = $1_1;
     HEAP32[($1_1 + 12 | 0) >> 2] = $3_1;
     HEAP32[($1_1 + 8 | 0) >> 2] = $0_1;
     return;
    }
    $3_1 = 31;
    block40 : {
     if ($0_1 >>> 0 > 16777215 >>> 0) {
      break block40
     }
     $3_1 = Math_clz32($0_1 >>> 8 | 0);
     $3_1 = ((($0_1 >>> (38 - $3_1 | 0) | 0) & 1 | 0) - ($3_1 << 1 | 0) | 0) + 62 | 0;
    }
    HEAP32[($1_1 + 28 | 0) >> 2] = $3_1;
    HEAP32[($1_1 + 16 | 0) >> 2] = 0;
    HEAP32[($1_1 + 20 | 0) >> 2] = 0;
    $6_1 = ($3_1 << 2 | 0) + 70200 | 0;
    block44 : {
     block43 : {
      block42 : {
       block41 : {
        $5_1 = HEAP32[(0 + 69900 | 0) >> 2] | 0;
        $4_1 = 1 << $3_1 | 0;
        if ($5_1 & $4_1 | 0) {
         break block41
        }
        HEAP32[(0 + 69900 | 0) >> 2] = $5_1 | $4_1 | 0;
        HEAP32[$6_1 >> 2] = $1_1;
        $0_1 = 8;
        $3_1 = 24;
        break block42;
       }
       $3_1 = $0_1 << (($3_1 | 0) == (31 | 0) ? 0 : 25 - ($3_1 >>> 1 | 0) | 0) | 0;
       $6_1 = HEAP32[$6_1 >> 2] | 0;
       label2 : while (1) {
        $5_1 = $6_1;
        if (((HEAP32[($5_1 + 4 | 0) >> 2] | 0) & -8 | 0 | 0) == ($0_1 | 0)) {
         break block43
        }
        $6_1 = $3_1 >>> 29 | 0;
        $3_1 = $3_1 << 1 | 0;
        $4_1 = $5_1 + ($6_1 & 4 | 0) | 0;
        $6_1 = HEAP32[($4_1 + 16 | 0) >> 2] | 0;
        if ($6_1) {
         continue label2
        }
        break label2;
       };
       $0_1 = $4_1 + 16 | 0;
       if ($0_1 >>> 0 < $2_1 >>> 0) {
        break block1
       }
       HEAP32[$0_1 >> 2] = $1_1;
       $0_1 = 8;
       $3_1 = 24;
       $6_1 = $5_1;
      }
      $5_1 = $1_1;
      $4_1 = $5_1;
      break block44;
     }
     if ($5_1 >>> 0 < $2_1 >>> 0) {
      break block1
     }
     $6_1 = HEAP32[($5_1 + 8 | 0) >> 2] | 0;
     if ($6_1 >>> 0 < $2_1 >>> 0) {
      break block1
     }
     HEAP32[($6_1 + 12 | 0) >> 2] = $1_1;
     HEAP32[($5_1 + 8 | 0) >> 2] = $1_1;
     $4_1 = 0;
     $0_1 = 24;
     $3_1 = 8;
    }
    HEAP32[($1_1 + $3_1 | 0) >> 2] = $6_1;
    HEAP32[($1_1 + 12 | 0) >> 2] = $5_1;
    HEAP32[($1_1 + $0_1 | 0) >> 2] = $4_1;
    $1_1 = (HEAP32[(0 + 69928 | 0) >> 2] | 0) + -1 | 0;
    HEAP32[(0 + 69928 | 0) >> 2] = $1_1 ? $1_1 : -1;
   }
   return;
  }
  $42();
  wasm2js_trap();
 }
 
 function $50() {
  return __wasm_memory_size() << 16 | 0 | 0;
 }
 
 function $51($0_1) {
  $0_1 = $0_1 | 0;
  var i64toi32_i32$2 = 0, i64toi32_i32$4 = 0, i64toi32_i32$3 = 0, i64toi32_i32$5 = 0, i64toi32_i32$1 = 0, i64toi32_i32$0 = 0, $6$hi = 0, $9$hi = 0, $2_1 = 0, wasm2js_i32$0 = 0, wasm2js_i32$1 = 0;
  block1 : {
   block : {
    i64toi32_i32$0 = 0;
    i64toi32_i32$2 = $0_1;
    i64toi32_i32$1 = 0;
    i64toi32_i32$3 = 7;
    i64toi32_i32$4 = i64toi32_i32$2 + i64toi32_i32$3 | 0;
    i64toi32_i32$5 = i64toi32_i32$0 + i64toi32_i32$1 | 0;
    if (i64toi32_i32$4 >>> 0 < i64toi32_i32$3 >>> 0) {
     i64toi32_i32$5 = i64toi32_i32$5 + 1 | 0
    }
    i64toi32_i32$0 = i64toi32_i32$4;
    i64toi32_i32$2 = 1;
    i64toi32_i32$3 = -8;
    i64toi32_i32$2 = i64toi32_i32$5 & i64toi32_i32$2 | 0;
    $6$hi = i64toi32_i32$2;
    $0_1 = HEAP32[(0 + 68652 | 0) >> 2] | 0;
    i64toi32_i32$2 = 0;
    $9$hi = i64toi32_i32$2;
    i64toi32_i32$2 = $6$hi;
    i64toi32_i32$5 = i64toi32_i32$4 & i64toi32_i32$3 | 0;
    i64toi32_i32$0 = $9$hi;
    i64toi32_i32$3 = $0_1;
    i64toi32_i32$1 = i64toi32_i32$5 + i64toi32_i32$3 | 0;
    i64toi32_i32$4 = i64toi32_i32$2 + i64toi32_i32$0 | 0;
    if (i64toi32_i32$1 >>> 0 < i64toi32_i32$3 >>> 0) {
     i64toi32_i32$4 = i64toi32_i32$4 + 1 | 0
    }
    i64toi32_i32$2 = i64toi32_i32$1;
    i64toi32_i32$5 = 0;
    i64toi32_i32$3 = -1;
    if (i64toi32_i32$4 >>> 0 > i64toi32_i32$5 >>> 0 | ((i64toi32_i32$4 | 0) == (i64toi32_i32$5 | 0) & i64toi32_i32$2 >>> 0 > i64toi32_i32$3 >>> 0 | 0) | 0) {
     break block
    }
    i64toi32_i32$2 = i64toi32_i32$4;
    i64toi32_i32$2 = i64toi32_i32$4;
    $2_1 = i64toi32_i32$1;
    if (($50() | 0) >>> 0 >= i64toi32_i32$1 >>> 0) {
     break block1
    }
    if (fimport$3(i64toi32_i32$1 | 0) | 0) {
     break block1
    }
   }
   (wasm2js_i32$0 = $16() | 0, wasm2js_i32$1 = 48), HEAP32[wasm2js_i32$0 >> 2] = wasm2js_i32$1;
   return -1 | 0;
  }
  HEAP32[(0 + 68652 | 0) >> 2] = $2_1;
  return $0_1 | 0;
 }
 
 function $52() {
  global$2 = 65536;
  global$1 = (0 + 15 | 0) & -16 | 0;
 }
 
 function $53() {
  return global$0 - global$1 | 0 | 0;
 }
 
 function $54() {
  return global$2 | 0;
 }
 
 function $55() {
  return global$1 | 0;
 }
 
 function $56($0_1, $1_1, $1$hi, $2_1, $2$hi, $3_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  $2$hi = $2$hi | 0;
  $3_1 = $3_1 | 0;
  var i64toi32_i32$1 = 0, i64toi32_i32$4 = 0, i64toi32_i32$2 = 0, i64toi32_i32$0 = 0, i64toi32_i32$3 = 0, $4$hi = 0, $18_1 = 0, $20_1 = 0, $21_1 = 0, $22_1 = 0, $11$hi = 0, $18$hi = 0, $19_1 = 0, $19$hi = 0, $4_1 = 0, $24$hi = 0;
  block1 : {
   block : {
    if (!($3_1 & 64 | 0)) {
     break block
    }
    i64toi32_i32$0 = $1$hi;
    i64toi32_i32$0 = 0;
    $11$hi = i64toi32_i32$0;
    i64toi32_i32$0 = $1$hi;
    i64toi32_i32$2 = $1_1;
    i64toi32_i32$1 = $11$hi;
    i64toi32_i32$3 = $3_1 + -64 | 0;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
     $18_1 = 0;
    } else {
     i64toi32_i32$1 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$2 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$0 << i64toi32_i32$4 | 0) | 0;
     $18_1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
    }
    $2_1 = $18_1;
    $2$hi = i64toi32_i32$1;
    i64toi32_i32$1 = 0;
    $1_1 = 0;
    $1$hi = i64toi32_i32$1;
    break block1;
   }
   if (!$3_1) {
    break block1
   }
   i64toi32_i32$1 = $1$hi;
   i64toi32_i32$1 = 0;
   $18$hi = i64toi32_i32$1;
   i64toi32_i32$1 = $1$hi;
   i64toi32_i32$0 = $1_1;
   i64toi32_i32$2 = $18$hi;
   i64toi32_i32$3 = 64 - $3_1 | 0;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = 0;
    $20_1 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
   } else {
    i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
    $20_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$0 >>> i64toi32_i32$4 | 0) | 0;
   }
   $19_1 = $20_1;
   $19$hi = i64toi32_i32$2;
   i64toi32_i32$2 = $2$hi;
   i64toi32_i32$2 = 0;
   $4_1 = $3_1;
   $4$hi = i64toi32_i32$2;
   i64toi32_i32$2 = $2$hi;
   i64toi32_i32$1 = $2_1;
   i64toi32_i32$0 = $4$hi;
   i64toi32_i32$3 = $3_1;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$0 = i64toi32_i32$1 << i64toi32_i32$4 | 0;
    $21_1 = 0;
   } else {
    i64toi32_i32$0 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$1 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$2 << i64toi32_i32$4 | 0) | 0;
    $21_1 = i64toi32_i32$1 << i64toi32_i32$4 | 0;
   }
   $24$hi = i64toi32_i32$0;
   i64toi32_i32$0 = $19$hi;
   i64toi32_i32$2 = $19_1;
   i64toi32_i32$1 = $24$hi;
   i64toi32_i32$3 = $21_1;
   i64toi32_i32$1 = i64toi32_i32$0 | i64toi32_i32$1 | 0;
   $2_1 = i64toi32_i32$2 | i64toi32_i32$3 | 0;
   $2$hi = i64toi32_i32$1;
   i64toi32_i32$1 = $1$hi;
   i64toi32_i32$1 = $4$hi;
   i64toi32_i32$1 = $1$hi;
   i64toi32_i32$0 = $1_1;
   i64toi32_i32$2 = $4$hi;
   i64toi32_i32$3 = $4_1;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
    $22_1 = 0;
   } else {
    i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$0 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$1 << i64toi32_i32$4 | 0) | 0;
    $22_1 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
   }
   $1_1 = $22_1;
   $1$hi = i64toi32_i32$2;
  }
  i64toi32_i32$2 = $1$hi;
  i64toi32_i32$0 = $0_1;
  HEAP32[i64toi32_i32$0 >> 2] = $1_1;
  HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$2;
  i64toi32_i32$2 = $2$hi;
  HEAP32[(i64toi32_i32$0 + 8 | 0) >> 2] = $2_1;
  HEAP32[(i64toi32_i32$0 + 12 | 0) >> 2] = i64toi32_i32$2;
 }
 
 function $57($0_1, $1_1, $1$hi, $2_1, $2$hi, $3_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  $2$hi = $2$hi | 0;
  $3_1 = $3_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$4 = 0, i64toi32_i32$2 = 0, i64toi32_i32$1 = 0, i64toi32_i32$3 = 0, $4$hi = 0, $18_1 = 0, $20_1 = 0, $21_1 = 0, $22_1 = 0, $11$hi = 0, $18$hi = 0, $19_1 = 0, $19$hi = 0, $4_1 = 0, $24$hi = 0;
  block1 : {
   block : {
    if (!($3_1 & 64 | 0)) {
     break block
    }
    i64toi32_i32$0 = $2$hi;
    i64toi32_i32$0 = 0;
    $11$hi = i64toi32_i32$0;
    i64toi32_i32$0 = $2$hi;
    i64toi32_i32$2 = $2_1;
    i64toi32_i32$1 = $11$hi;
    i64toi32_i32$3 = $3_1 + -64 | 0;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = 0;
     $18_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
     $18_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
    }
    $1_1 = $18_1;
    $1$hi = i64toi32_i32$1;
    i64toi32_i32$1 = 0;
    $2_1 = 0;
    $2$hi = i64toi32_i32$1;
    break block1;
   }
   if (!$3_1) {
    break block1
   }
   i64toi32_i32$1 = $2$hi;
   i64toi32_i32$1 = 0;
   $18$hi = i64toi32_i32$1;
   i64toi32_i32$1 = $2$hi;
   i64toi32_i32$0 = $2_1;
   i64toi32_i32$2 = $18$hi;
   i64toi32_i32$3 = 64 - $3_1 | 0;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
    $20_1 = 0;
   } else {
    i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$0 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$1 << i64toi32_i32$4 | 0) | 0;
    $20_1 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
   }
   $19_1 = $20_1;
   $19$hi = i64toi32_i32$2;
   i64toi32_i32$2 = $1$hi;
   i64toi32_i32$2 = 0;
   $4_1 = $3_1;
   $4$hi = i64toi32_i32$2;
   i64toi32_i32$2 = $1$hi;
   i64toi32_i32$1 = $1_1;
   i64toi32_i32$0 = $4$hi;
   i64toi32_i32$3 = $3_1;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$0 = 0;
    $21_1 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
   } else {
    i64toi32_i32$0 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
    $21_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$2 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$1 >>> i64toi32_i32$4 | 0) | 0;
   }
   $24$hi = i64toi32_i32$0;
   i64toi32_i32$0 = $19$hi;
   i64toi32_i32$2 = $19_1;
   i64toi32_i32$1 = $24$hi;
   i64toi32_i32$3 = $21_1;
   i64toi32_i32$1 = i64toi32_i32$0 | i64toi32_i32$1 | 0;
   $1_1 = i64toi32_i32$2 | i64toi32_i32$3 | 0;
   $1$hi = i64toi32_i32$1;
   i64toi32_i32$1 = $2$hi;
   i64toi32_i32$1 = $4$hi;
   i64toi32_i32$1 = $2$hi;
   i64toi32_i32$0 = $2_1;
   i64toi32_i32$2 = $4$hi;
   i64toi32_i32$3 = $4_1;
   i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = 0;
    $22_1 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
   } else {
    i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
    $22_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$0 >>> i64toi32_i32$4 | 0) | 0;
   }
   $2_1 = $22_1;
   $2$hi = i64toi32_i32$2;
  }
  i64toi32_i32$2 = $1$hi;
  i64toi32_i32$0 = $0_1;
  HEAP32[i64toi32_i32$0 >> 2] = $1_1;
  HEAP32[(i64toi32_i32$0 + 4 | 0) >> 2] = i64toi32_i32$2;
  i64toi32_i32$2 = $2$hi;
  HEAP32[(i64toi32_i32$0 + 8 | 0) >> 2] = $2_1;
  HEAP32[(i64toi32_i32$0 + 12 | 0) >> 2] = i64toi32_i32$2;
 }
 
 function $58($0_1, $0$hi, $1_1, $1$hi) {
  $0_1 = $0_1 | 0;
  $0$hi = $0$hi | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  var i64toi32_i32$3 = 0, i64toi32_i32$2 = 0, i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$5 = 0, i64toi32_i32$4 = 0, $7_1 = 0, $7$hi = 0, $3_1 = 0, $2_1 = 0, $8_1 = 0, $8$hi = 0, $4_1 = 0, $6_1 = 0, $45_1 = 0, $46_1 = 0, $47_1 = 0, $48_1 = 0, $49_1 = 0, $5_1 = 0, $50_1 = 0, $51_1 = 0, $52_1 = 0, $23_1 = 0, $23$hi = 0, $25$hi = 0, $39$hi = 0, $48$hi = 0, $58_1 = 0, $58$hi = 0, $60$hi = 0, $76 = 0, $76$hi = 0, $89 = 0, $89$hi = 0, $91 = 0, $91$hi = 0, $101 = 0, $101$hi = 0, $104$hi = 0, $107$hi = 0, $109$hi = 0, $118$hi = 0, $122 = 0, $122$hi = 0, $133$hi = 0, $135 = 0, $135$hi = 0, $136$hi = 0;
  $2_1 = global$0 - 32 | 0;
  global$0 = $2_1;
  i64toi32_i32$0 = $1$hi;
  i64toi32_i32$2 = $1_1;
  i64toi32_i32$1 = 65535;
  i64toi32_i32$3 = -1;
  i64toi32_i32$1 = i64toi32_i32$0 & i64toi32_i32$1 | 0;
  $7_1 = i64toi32_i32$2 & i64toi32_i32$3 | 0;
  $7$hi = i64toi32_i32$1;
  block3 : {
   block : {
    i64toi32_i32$1 = i64toi32_i32$0;
    i64toi32_i32$1 = i64toi32_i32$0;
    i64toi32_i32$0 = i64toi32_i32$2;
    i64toi32_i32$2 = 0;
    i64toi32_i32$3 = 48;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$2 = 0;
     $45_1 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
     $45_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$0 >>> i64toi32_i32$4 | 0) | 0;
    }
    i64toi32_i32$1 = $45_1;
    i64toi32_i32$0 = 0;
    i64toi32_i32$3 = 32767;
    i64toi32_i32$0 = i64toi32_i32$2 & i64toi32_i32$0 | 0;
    $8_1 = i64toi32_i32$1 & i64toi32_i32$3 | 0;
    $8$hi = i64toi32_i32$0;
    $3_1 = $8_1;
    if (($3_1 + -15361 | 0) >>> 0 > 2045 >>> 0) {
     break block
    }
    i64toi32_i32$0 = $0$hi;
    i64toi32_i32$2 = $0_1;
    i64toi32_i32$1 = 0;
    i64toi32_i32$3 = 60;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = 0;
     $46_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
     $46_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
    }
    $23_1 = $46_1;
    $23$hi = i64toi32_i32$1;
    i64toi32_i32$1 = $7$hi;
    i64toi32_i32$0 = $7_1;
    i64toi32_i32$2 = 0;
    i64toi32_i32$3 = 4;
    i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$2 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
     $47_1 = 0;
    } else {
     i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$0 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$1 << i64toi32_i32$4 | 0) | 0;
     $47_1 = i64toi32_i32$0 << i64toi32_i32$4 | 0;
    }
    $25$hi = i64toi32_i32$2;
    i64toi32_i32$2 = $23$hi;
    i64toi32_i32$1 = $23_1;
    i64toi32_i32$0 = $25$hi;
    i64toi32_i32$3 = $47_1;
    i64toi32_i32$0 = i64toi32_i32$2 | i64toi32_i32$0 | 0;
    $7_1 = i64toi32_i32$1 | i64toi32_i32$3 | 0;
    $7$hi = i64toi32_i32$0;
    i64toi32_i32$0 = 0;
    $8_1 = $3_1 + -15360 | 0;
    $8$hi = i64toi32_i32$0;
    block2 : {
     block1 : {
      i64toi32_i32$0 = $0$hi;
      i64toi32_i32$2 = $0_1;
      i64toi32_i32$1 = 268435455;
      i64toi32_i32$3 = -1;
      i64toi32_i32$1 = i64toi32_i32$0 & i64toi32_i32$1 | 0;
      $0_1 = i64toi32_i32$2 & i64toi32_i32$3 | 0;
      $0$hi = i64toi32_i32$1;
      i64toi32_i32$0 = $0_1;
      i64toi32_i32$2 = 134217728;
      i64toi32_i32$3 = 1;
      if (i64toi32_i32$1 >>> 0 < i64toi32_i32$2 >>> 0 | ((i64toi32_i32$1 | 0) == (i64toi32_i32$2 | 0) & i64toi32_i32$0 >>> 0 < i64toi32_i32$3 >>> 0 | 0) | 0) {
       break block1
      }
      i64toi32_i32$0 = $7$hi;
      i64toi32_i32$3 = $7_1;
      i64toi32_i32$1 = 0;
      i64toi32_i32$2 = 1;
      i64toi32_i32$4 = i64toi32_i32$3 + i64toi32_i32$2 | 0;
      i64toi32_i32$5 = i64toi32_i32$0 + i64toi32_i32$1 | 0;
      if (i64toi32_i32$4 >>> 0 < i64toi32_i32$2 >>> 0) {
       i64toi32_i32$5 = i64toi32_i32$5 + 1 | 0
      }
      $7_1 = i64toi32_i32$4;
      $7$hi = i64toi32_i32$5;
      break block2;
     }
     i64toi32_i32$5 = $0$hi;
     i64toi32_i32$0 = $0_1;
     i64toi32_i32$3 = 134217728;
     i64toi32_i32$2 = 0;
     if ((i64toi32_i32$0 | 0) != (i64toi32_i32$2 | 0) | (i64toi32_i32$5 | 0) != (i64toi32_i32$3 | 0) | 0) {
      break block2
     }
     i64toi32_i32$0 = $7$hi;
     i64toi32_i32$2 = $7_1;
     i64toi32_i32$5 = 0;
     i64toi32_i32$3 = 1;
     i64toi32_i32$5 = i64toi32_i32$0 & i64toi32_i32$5 | 0;
     $39$hi = i64toi32_i32$5;
     i64toi32_i32$5 = i64toi32_i32$0;
     i64toi32_i32$5 = $39$hi;
     i64toi32_i32$0 = i64toi32_i32$2 & i64toi32_i32$3 | 0;
     i64toi32_i32$2 = $7$hi;
     i64toi32_i32$3 = $7_1;
     i64toi32_i32$1 = i64toi32_i32$0 + i64toi32_i32$3 | 0;
     i64toi32_i32$4 = i64toi32_i32$5 + i64toi32_i32$2 | 0;
     if (i64toi32_i32$1 >>> 0 < i64toi32_i32$3 >>> 0) {
      i64toi32_i32$4 = i64toi32_i32$4 + 1 | 0
     }
     $7_1 = i64toi32_i32$1;
     $7$hi = i64toi32_i32$4;
    }
    i64toi32_i32$4 = $7$hi;
    i64toi32_i32$5 = $7_1;
    i64toi32_i32$0 = 1048575;
    i64toi32_i32$3 = -1;
    $3_1 = i64toi32_i32$4 >>> 0 > i64toi32_i32$0 >>> 0 | ((i64toi32_i32$4 | 0) == (i64toi32_i32$0 | 0) & i64toi32_i32$5 >>> 0 > i64toi32_i32$3 >>> 0 | 0) | 0;
    i64toi32_i32$2 = $3_1;
    i64toi32_i32$5 = 0;
    i64toi32_i32$0 = i64toi32_i32$2 ? 0 : $7_1;
    i64toi32_i32$3 = i64toi32_i32$2 ? i64toi32_i32$5 : i64toi32_i32$4;
    $0_1 = i64toi32_i32$0;
    $0$hi = i64toi32_i32$3;
    i64toi32_i32$3 = 0;
    $48$hi = i64toi32_i32$3;
    i64toi32_i32$3 = $8$hi;
    i64toi32_i32$3 = $48$hi;
    i64toi32_i32$0 = $8$hi;
    i64toi32_i32$5 = $8_1;
    i64toi32_i32$4 = i64toi32_i32$2 + i64toi32_i32$5 | 0;
    i64toi32_i32$1 = i64toi32_i32$3 + i64toi32_i32$0 | 0;
    if (i64toi32_i32$4 >>> 0 < i64toi32_i32$5 >>> 0) {
     i64toi32_i32$1 = i64toi32_i32$1 + 1 | 0
    }
    $7_1 = i64toi32_i32$4;
    $7$hi = i64toi32_i32$1;
    break block3;
   }
   block4 : {
    i64toi32_i32$1 = $0$hi;
    i64toi32_i32$1 = $7$hi;
    i64toi32_i32$1 = $0$hi;
    i64toi32_i32$3 = $0_1;
    i64toi32_i32$2 = $7$hi;
    i64toi32_i32$5 = $7_1;
    i64toi32_i32$2 = i64toi32_i32$1 | i64toi32_i32$2 | 0;
    if (!(i64toi32_i32$3 | i64toi32_i32$5 | 0 | i64toi32_i32$2 | 0)) {
     break block4
    }
    i64toi32_i32$2 = $8$hi;
    i64toi32_i32$1 = $8_1;
    i64toi32_i32$3 = 0;
    i64toi32_i32$5 = 32767;
    if ((i64toi32_i32$1 | 0) != (i64toi32_i32$5 | 0) | (i64toi32_i32$2 | 0) != (i64toi32_i32$3 | 0) | 0) {
     break block4
    }
    i64toi32_i32$1 = $0$hi;
    i64toi32_i32$5 = $0_1;
    i64toi32_i32$2 = 0;
    i64toi32_i32$3 = 60;
    i64toi32_i32$0 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$2 = 0;
     $48_1 = i64toi32_i32$1 >>> i64toi32_i32$0 | 0;
    } else {
     i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$0 | 0;
     $48_1 = (((1 << i64toi32_i32$0 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$0 | 0) | 0 | (i64toi32_i32$5 >>> i64toi32_i32$0 | 0) | 0;
    }
    $58_1 = $48_1;
    $58$hi = i64toi32_i32$2;
    i64toi32_i32$2 = $7$hi;
    i64toi32_i32$1 = $7_1;
    i64toi32_i32$5 = 0;
    i64toi32_i32$3 = 4;
    i64toi32_i32$0 = i64toi32_i32$3 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
     i64toi32_i32$5 = i64toi32_i32$1 << i64toi32_i32$0 | 0;
     $49_1 = 0;
    } else {
     i64toi32_i32$5 = ((1 << i64toi32_i32$0 | 0) - 1 | 0) & (i64toi32_i32$1 >>> (32 - i64toi32_i32$0 | 0) | 0) | 0 | (i64toi32_i32$2 << i64toi32_i32$0 | 0) | 0;
     $49_1 = i64toi32_i32$1 << i64toi32_i32$0 | 0;
    }
    $60$hi = i64toi32_i32$5;
    i64toi32_i32$5 = $58$hi;
    i64toi32_i32$2 = $58_1;
    i64toi32_i32$1 = $60$hi;
    i64toi32_i32$3 = $49_1;
    i64toi32_i32$1 = i64toi32_i32$5 | i64toi32_i32$1 | 0;
    i64toi32_i32$5 = i64toi32_i32$2 | i64toi32_i32$3 | 0;
    i64toi32_i32$2 = 524288;
    i64toi32_i32$3 = 0;
    i64toi32_i32$2 = i64toi32_i32$1 | i64toi32_i32$2 | 0;
    $0_1 = i64toi32_i32$5 | i64toi32_i32$3 | 0;
    $0$hi = i64toi32_i32$2;
    i64toi32_i32$2 = 0;
    $7_1 = 2047;
    $7$hi = i64toi32_i32$2;
    break block3;
   }
   block5 : {
    if ($3_1 >>> 0 <= 17406 >>> 0) {
     break block5
    }
    i64toi32_i32$2 = 0;
    $7_1 = 2047;
    $7$hi = i64toi32_i32$2;
    i64toi32_i32$2 = 0;
    $0_1 = 0;
    $0$hi = i64toi32_i32$2;
    break block3;
   }
   block6 : {
    i64toi32_i32$2 = $8$hi;
    $4_1 = !($8_1 | i64toi32_i32$2 | 0);
    $5_1 = $4_1 ? 15360 : 15361;
    $6_1 = $5_1 - $3_1 | 0;
    if (($6_1 | 0) <= (112 | 0)) {
     break block6
    }
    i64toi32_i32$2 = 0;
    $0_1 = 0;
    $0$hi = i64toi32_i32$2;
    i64toi32_i32$2 = 0;
    $7_1 = 0;
    $7$hi = i64toi32_i32$2;
    break block3;
   }
   i64toi32_i32$2 = $7$hi;
   i64toi32_i32$1 = $7_1;
   i64toi32_i32$5 = 65536;
   i64toi32_i32$3 = 0;
   i64toi32_i32$5 = i64toi32_i32$2 | i64toi32_i32$5 | 0;
   $76 = i64toi32_i32$1 | i64toi32_i32$3 | 0;
   $76$hi = i64toi32_i32$5;
   i64toi32_i32$0 = $4_1;
   i64toi32_i32$5 = i64toi32_i32$2;
   i64toi32_i32$1 = $76$hi;
   i64toi32_i32$3 = i64toi32_i32$0 ? $7_1 : $76;
   i64toi32_i32$2 = i64toi32_i32$0 ? i64toi32_i32$2 : i64toi32_i32$1;
   $7_1 = i64toi32_i32$3;
   $7$hi = i64toi32_i32$2;
   $4_1 = 0;
   block7 : {
    if (($5_1 | 0) == ($3_1 | 0)) {
     break block7
    }
    i64toi32_i32$2 = $0$hi;
    i64toi32_i32$2 = $7$hi;
    i64toi32_i32$2 = $0$hi;
    i64toi32_i32$3 = $7$hi;
    $56($2_1 + 16 | 0 | 0, $0_1 | 0, i64toi32_i32$2 | 0, $7_1 | 0, i64toi32_i32$3 | 0, 128 - $6_1 | 0 | 0);
    i64toi32_i32$0 = $2_1;
    i64toi32_i32$3 = HEAP32[(i64toi32_i32$0 + 16 | 0) >> 2] | 0;
    i64toi32_i32$2 = HEAP32[(i64toi32_i32$0 + 20 | 0) >> 2] | 0;
    $89 = i64toi32_i32$3;
    $89$hi = i64toi32_i32$2;
    i64toi32_i32$2 = HEAP32[(i64toi32_i32$0 + 24 | 0) >> 2] | 0;
    i64toi32_i32$3 = HEAP32[(i64toi32_i32$0 + 28 | 0) >> 2] | 0;
    $91 = i64toi32_i32$2;
    $91$hi = i64toi32_i32$3;
    i64toi32_i32$3 = $89$hi;
    i64toi32_i32$0 = $89;
    i64toi32_i32$2 = $91$hi;
    i64toi32_i32$5 = $91;
    i64toi32_i32$2 = i64toi32_i32$3 | i64toi32_i32$2 | 0;
    i64toi32_i32$3 = i64toi32_i32$0 | i64toi32_i32$5 | 0;
    i64toi32_i32$0 = 0;
    i64toi32_i32$5 = 0;
    $4_1 = (i64toi32_i32$3 | 0) != (i64toi32_i32$5 | 0) | (i64toi32_i32$2 | 0) != (i64toi32_i32$0 | 0) | 0;
   }
   i64toi32_i32$3 = $0$hi;
   i64toi32_i32$3 = $7$hi;
   i64toi32_i32$3 = $0$hi;
   i64toi32_i32$2 = $7$hi;
   $57($2_1 | 0, $0_1 | 0, i64toi32_i32$3 | 0, $7_1 | 0, i64toi32_i32$2 | 0, $6_1 | 0);
   i64toi32_i32$5 = $2_1;
   i64toi32_i32$2 = HEAP32[i64toi32_i32$5 >> 2] | 0;
   i64toi32_i32$3 = HEAP32[(i64toi32_i32$5 + 4 | 0) >> 2] | 0;
   $7_1 = i64toi32_i32$2;
   $7$hi = i64toi32_i32$3;
   i64toi32_i32$5 = i64toi32_i32$2;
   i64toi32_i32$2 = 0;
   i64toi32_i32$0 = 60;
   i64toi32_i32$1 = i64toi32_i32$0 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = 0;
    $50_1 = i64toi32_i32$3 >>> i64toi32_i32$1 | 0;
   } else {
    i64toi32_i32$2 = i64toi32_i32$3 >>> i64toi32_i32$1 | 0;
    $50_1 = (((1 << i64toi32_i32$1 | 0) - 1 | 0) & i64toi32_i32$3 | 0) << (32 - i64toi32_i32$1 | 0) | 0 | (i64toi32_i32$5 >>> i64toi32_i32$1 | 0) | 0;
   }
   $101 = $50_1;
   $101$hi = i64toi32_i32$2;
   i64toi32_i32$3 = $2_1;
   i64toi32_i32$2 = HEAP32[(i64toi32_i32$3 + 8 | 0) >> 2] | 0;
   i64toi32_i32$5 = HEAP32[(i64toi32_i32$3 + 12 | 0) >> 2] | 0;
   i64toi32_i32$3 = i64toi32_i32$2;
   i64toi32_i32$2 = 0;
   i64toi32_i32$0 = 4;
   i64toi32_i32$1 = i64toi32_i32$0 & 31 | 0;
   if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
    i64toi32_i32$2 = i64toi32_i32$3 << i64toi32_i32$1 | 0;
    $51_1 = 0;
   } else {
    i64toi32_i32$2 = ((1 << i64toi32_i32$1 | 0) - 1 | 0) & (i64toi32_i32$3 >>> (32 - i64toi32_i32$1 | 0) | 0) | 0 | (i64toi32_i32$5 << i64toi32_i32$1 | 0) | 0;
    $51_1 = i64toi32_i32$3 << i64toi32_i32$1 | 0;
   }
   $104$hi = i64toi32_i32$2;
   i64toi32_i32$2 = $101$hi;
   i64toi32_i32$5 = $101;
   i64toi32_i32$3 = $104$hi;
   i64toi32_i32$0 = $51_1;
   i64toi32_i32$3 = i64toi32_i32$2 | i64toi32_i32$3 | 0;
   $0_1 = i64toi32_i32$5 | i64toi32_i32$0 | 0;
   $0$hi = i64toi32_i32$3;
   block9 : {
    block8 : {
     i64toi32_i32$3 = $7$hi;
     i64toi32_i32$2 = $7_1;
     i64toi32_i32$5 = 268435455;
     i64toi32_i32$0 = -1;
     i64toi32_i32$5 = i64toi32_i32$3 & i64toi32_i32$5 | 0;
     $107$hi = i64toi32_i32$5;
     i64toi32_i32$5 = 0;
     $109$hi = i64toi32_i32$5;
     i64toi32_i32$5 = $107$hi;
     i64toi32_i32$3 = i64toi32_i32$2 & i64toi32_i32$0 | 0;
     i64toi32_i32$2 = $109$hi;
     i64toi32_i32$0 = $4_1;
     i64toi32_i32$2 = i64toi32_i32$5 | i64toi32_i32$2 | 0;
     $7_1 = i64toi32_i32$3 | i64toi32_i32$0 | 0;
     $7$hi = i64toi32_i32$2;
     i64toi32_i32$5 = $7_1;
     i64toi32_i32$3 = 134217728;
     i64toi32_i32$0 = 1;
     if (i64toi32_i32$2 >>> 0 < i64toi32_i32$3 >>> 0 | ((i64toi32_i32$2 | 0) == (i64toi32_i32$3 | 0) & i64toi32_i32$5 >>> 0 < i64toi32_i32$0 >>> 0 | 0) | 0) {
      break block8
     }
     i64toi32_i32$5 = $0$hi;
     i64toi32_i32$0 = $0_1;
     i64toi32_i32$2 = 0;
     i64toi32_i32$3 = 1;
     i64toi32_i32$1 = i64toi32_i32$0 + i64toi32_i32$3 | 0;
     i64toi32_i32$4 = i64toi32_i32$5 + i64toi32_i32$2 | 0;
     if (i64toi32_i32$1 >>> 0 < i64toi32_i32$3 >>> 0) {
      i64toi32_i32$4 = i64toi32_i32$4 + 1 | 0
     }
     $0_1 = i64toi32_i32$1;
     $0$hi = i64toi32_i32$4;
     break block9;
    }
    i64toi32_i32$4 = $7$hi;
    i64toi32_i32$5 = $7_1;
    i64toi32_i32$0 = 134217728;
    i64toi32_i32$3 = 0;
    if ((i64toi32_i32$5 | 0) != (i64toi32_i32$3 | 0) | (i64toi32_i32$4 | 0) != (i64toi32_i32$0 | 0) | 0) {
     break block9
    }
    i64toi32_i32$5 = $0$hi;
    i64toi32_i32$3 = $0_1;
    i64toi32_i32$4 = 0;
    i64toi32_i32$0 = 1;
    i64toi32_i32$4 = i64toi32_i32$5 & i64toi32_i32$4 | 0;
    $118$hi = i64toi32_i32$4;
    i64toi32_i32$4 = i64toi32_i32$5;
    i64toi32_i32$4 = $118$hi;
    i64toi32_i32$5 = i64toi32_i32$3 & i64toi32_i32$0 | 0;
    i64toi32_i32$3 = $0$hi;
    i64toi32_i32$0 = $0_1;
    i64toi32_i32$2 = i64toi32_i32$5 + i64toi32_i32$0 | 0;
    i64toi32_i32$1 = i64toi32_i32$4 + i64toi32_i32$3 | 0;
    if (i64toi32_i32$2 >>> 0 < i64toi32_i32$0 >>> 0) {
     i64toi32_i32$1 = i64toi32_i32$1 + 1 | 0
    }
    $0_1 = i64toi32_i32$2;
    $0$hi = i64toi32_i32$1;
   }
   i64toi32_i32$1 = $0$hi;
   i64toi32_i32$4 = $0_1;
   i64toi32_i32$5 = 1048576;
   i64toi32_i32$0 = 0;
   i64toi32_i32$5 = i64toi32_i32$1 ^ i64toi32_i32$5 | 0;
   $122 = i64toi32_i32$4 ^ i64toi32_i32$0 | 0;
   $122$hi = i64toi32_i32$5;
   i64toi32_i32$5 = i64toi32_i32$1;
   i64toi32_i32$5 = i64toi32_i32$1;
   i64toi32_i32$5 = i64toi32_i32$1;
   i64toi32_i32$1 = i64toi32_i32$4;
   i64toi32_i32$4 = 1048575;
   i64toi32_i32$0 = -1;
   $3_1 = i64toi32_i32$5 >>> 0 > i64toi32_i32$4 >>> 0 | ((i64toi32_i32$5 | 0) == (i64toi32_i32$4 | 0) & i64toi32_i32$1 >>> 0 > i64toi32_i32$0 >>> 0 | 0) | 0;
   i64toi32_i32$3 = $3_1;
   i64toi32_i32$1 = $122$hi;
   i64toi32_i32$4 = i64toi32_i32$3 ? $122 : $0_1;
   i64toi32_i32$0 = i64toi32_i32$3 ? i64toi32_i32$1 : i64toi32_i32$5;
   $0_1 = i64toi32_i32$4;
   $0$hi = i64toi32_i32$0;
   i64toi32_i32$0 = 0;
   $7_1 = i64toi32_i32$3;
   $7$hi = i64toi32_i32$0;
  }
  global$0 = $2_1 + 32 | 0;
  i64toi32_i32$0 = $7$hi;
  i64toi32_i32$3 = $7_1;
  i64toi32_i32$4 = 0;
  i64toi32_i32$1 = 52;
  i64toi32_i32$5 = i64toi32_i32$1 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$1 & 63 | 0) >>> 0) {
   i64toi32_i32$4 = i64toi32_i32$3 << i64toi32_i32$5 | 0;
   $52_1 = 0;
  } else {
   i64toi32_i32$4 = ((1 << i64toi32_i32$5 | 0) - 1 | 0) & (i64toi32_i32$3 >>> (32 - i64toi32_i32$5 | 0) | 0) | 0 | (i64toi32_i32$0 << i64toi32_i32$5 | 0) | 0;
   $52_1 = i64toi32_i32$3 << i64toi32_i32$5 | 0;
  }
  $133$hi = i64toi32_i32$4;
  i64toi32_i32$4 = $1$hi;
  i64toi32_i32$0 = $1_1;
  i64toi32_i32$3 = -2147483648;
  i64toi32_i32$1 = 0;
  i64toi32_i32$3 = i64toi32_i32$4 & i64toi32_i32$3 | 0;
  $135 = i64toi32_i32$0 & i64toi32_i32$1 | 0;
  $135$hi = i64toi32_i32$3;
  i64toi32_i32$3 = $133$hi;
  i64toi32_i32$4 = $52_1;
  i64toi32_i32$0 = $135$hi;
  i64toi32_i32$1 = $135;
  i64toi32_i32$0 = i64toi32_i32$3 | i64toi32_i32$0 | 0;
  $136$hi = i64toi32_i32$0;
  i64toi32_i32$0 = $0$hi;
  i64toi32_i32$0 = $136$hi;
  i64toi32_i32$3 = i64toi32_i32$4 | i64toi32_i32$1 | 0;
  i64toi32_i32$4 = $0$hi;
  i64toi32_i32$1 = $0_1;
  i64toi32_i32$4 = i64toi32_i32$0 | i64toi32_i32$4 | 0;
  wasm2js_scratch_store_i32(0 | 0, i64toi32_i32$3 | i64toi32_i32$1 | 0 | 0);
  wasm2js_scratch_store_i32(1 | 0, i64toi32_i32$4 | 0);
  return +(+wasm2js_scratch_load_f64());
 }
 
 function $59($0_1) {
  $0_1 = $0_1 | 0;
  global$3 = $0_1;
 }
 
 function $61($0_1) {
  $0_1 = $0_1 | 0;
  var $1_1 = 0, i64toi32_i32$1 = 0, $2_1 = 0, i64toi32_i32$0 = 0, $3_1 = 0;
  block : {
   if ($0_1) {
    break block
   }
   $1_1 = 0;
   block1 : {
    if (!(HEAP32[(0 + 68496 | 0) >> 2] | 0)) {
     break block1
    }
    $1_1 = $61(HEAP32[(0 + 68496 | 0) >> 2] | 0 | 0) | 0;
   }
   block2 : {
    if (!(HEAP32[(0 + 68648 | 0) >> 2] | 0)) {
     break block2
    }
    $1_1 = $61(HEAP32[(0 + 68648 | 0) >> 2] | 0 | 0) | 0 | $1_1 | 0;
   }
   block3 : {
    $0_1 = HEAP32[($11() | 0) >> 2] | 0;
    if (!$0_1) {
     break block3
    }
    label : while (1) {
     block5 : {
      block4 : {
       if ((HEAP32[($0_1 + 76 | 0) >> 2] | 0 | 0) >= (0 | 0)) {
        break block4
       }
       $2_1 = 1;
       break block5;
      }
      $2_1 = !($7($0_1 | 0) | 0);
     }
     block6 : {
      if ((HEAP32[($0_1 + 20 | 0) >> 2] | 0 | 0) == (HEAP32[($0_1 + 28 | 0) >> 2] | 0 | 0)) {
       break block6
      }
      $1_1 = $61($0_1 | 0) | 0 | $1_1 | 0;
     }
     block7 : {
      if ($2_1) {
       break block7
      }
      $8($0_1 | 0);
     }
     $0_1 = HEAP32[($0_1 + 56 | 0) >> 2] | 0;
     if ($0_1) {
      continue label
     }
     break label;
    };
   }
   $12();
   return $1_1 | 0;
  }
  block9 : {
   block8 : {
    if ((HEAP32[($0_1 + 76 | 0) >> 2] | 0 | 0) >= (0 | 0)) {
     break block8
    }
    $2_1 = 1;
    break block9;
   }
   $2_1 = !($7($0_1 | 0) | 0);
  }
  block12 : {
   block11 : {
    block10 : {
     if ((HEAP32[($0_1 + 20 | 0) >> 2] | 0 | 0) == (HEAP32[($0_1 + 28 | 0) >> 2] | 0 | 0)) {
      break block10
     }
     FUNCTION_TABLE[HEAP32[($0_1 + 36 | 0) >> 2] | 0 | 0]($0_1, 0, 0) | 0;
     if (HEAP32[($0_1 + 20 | 0) >> 2] | 0) {
      break block10
     }
     $1_1 = -1;
     if (!$2_1) {
      break block11
     }
     break block12;
    }
    block13 : {
     $1_1 = HEAP32[($0_1 + 4 | 0) >> 2] | 0;
     $3_1 = HEAP32[($0_1 + 8 | 0) >> 2] | 0;
     if (($1_1 | 0) == ($3_1 | 0)) {
      break block13
     }
     i64toi32_i32$1 = $1_1 - $3_1 | 0;
     i64toi32_i32$0 = i64toi32_i32$1 >> 31 | 0;
     i64toi32_i32$0 = FUNCTION_TABLE[HEAP32[($0_1 + 40 | 0) >> 2] | 0 | 0]($0_1, i64toi32_i32$1, i64toi32_i32$0, 1) | 0;
     i64toi32_i32$1 = i64toi32_i32$HIGH_BITS;
    }
    $1_1 = 0;
    HEAP32[($0_1 + 28 | 0) >> 2] = 0;
    i64toi32_i32$0 = $0_1;
    i64toi32_i32$1 = 0;
    HEAP32[($0_1 + 16 | 0) >> 2] = 0;
    HEAP32[($0_1 + 20 | 0) >> 2] = i64toi32_i32$1;
    i64toi32_i32$0 = $0_1;
    i64toi32_i32$1 = 0;
    HEAP32[($0_1 + 4 | 0) >> 2] = 0;
    HEAP32[($0_1 + 8 | 0) >> 2] = i64toi32_i32$1;
    if ($2_1) {
     break block12
    }
   }
   $8($0_1 | 0);
  }
  return $1_1 | 0;
 }
 
 function $62($0_1) {
  $0_1 = $0_1 | 0;
  global$0 = $0_1;
 }
 
 function $63($0_1) {
  $0_1 = $0_1 | 0;
  var $1_1 = 0;
  $1_1 = (global$0 - $0_1 | 0) & -16 | 0;
  global$0 = $1_1;
  return $1_1 | 0;
 }
 
 function $64() {
  return global$0 | 0;
 }
 
 function $65($0_1, $1_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  var $2_1 = 0;
  $2_1 = 65565;
  block : {
   if ($0_1 >>> 0 > 153 >>> 0) {
    break block
   }
   block2 : {
    block1 : {
     if ($0_1) {
      break block1
     }
     $0_1 = 0;
     break block2;
    }
    $0_1 = HEAPU16[(($0_1 << 1 | 0) + 66144 | 0) >> 1] | 0;
    if (!$0_1) {
     break block
    }
   }
   $2_1 = $0_1 + 66452 | 0;
  }
  return $2_1 | 0;
 }
 
 function $66($0_1) {
  $0_1 = $0_1 | 0;
  return $65($0_1 | 0, $0_1 | 0) | 0 | 0;
 }
 
 function $67($0_1, $1_1, $2_1, $2$hi, $3_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $2$hi = $2$hi | 0;
  $3_1 = $3_1 | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0;
  i64toi32_i32$0 = $2$hi;
  i64toi32_i32$0 = FUNCTION_TABLE[$0_1 | 0]($1_1, $2_1, i64toi32_i32$0, $3_1) | 0;
  i64toi32_i32$1 = i64toi32_i32$HIGH_BITS;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
  return i64toi32_i32$0 | 0;
 }
 
 function $68($0_1, $1_1, $2_1, $3_1, $4_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  $4_1 = $4_1 | 0;
  var i64toi32_i32$2 = 0, i64toi32_i32$4 = 0, i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$3 = 0, $17_1 = 0, $18_1 = 0, $6_1 = 0, $7_1 = 0, $9_1 = 0, $9$hi = 0, $12$hi = 0, $5_1 = 0, $5$hi = 0;
  $6_1 = $0_1;
  $7_1 = $1_1;
  i64toi32_i32$0 = 0;
  $9_1 = $2_1;
  $9$hi = i64toi32_i32$0;
  i64toi32_i32$0 = 0;
  i64toi32_i32$2 = $3_1;
  i64toi32_i32$1 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
   $17_1 = 0;
  } else {
   i64toi32_i32$1 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$2 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$0 << i64toi32_i32$4 | 0) | 0;
   $17_1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
  }
  $12$hi = i64toi32_i32$1;
  i64toi32_i32$1 = $9$hi;
  i64toi32_i32$0 = $9_1;
  i64toi32_i32$2 = $12$hi;
  i64toi32_i32$3 = $17_1;
  i64toi32_i32$2 = i64toi32_i32$1 | i64toi32_i32$2 | 0;
  i64toi32_i32$2 = $67($6_1 | 0, $7_1 | 0, i64toi32_i32$0 | i64toi32_i32$3 | 0 | 0, i64toi32_i32$2 | 0, $4_1 | 0) | 0;
  i64toi32_i32$0 = i64toi32_i32$HIGH_BITS;
  $5_1 = i64toi32_i32$2;
  $5$hi = i64toi32_i32$0;
  i64toi32_i32$1 = i64toi32_i32$2;
  i64toi32_i32$2 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$2 = 0;
   $18_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
  } else {
   i64toi32_i32$2 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
   $18_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$1 >>> i64toi32_i32$4 | 0) | 0;
  }
  $59($18_1 | 0);
  i64toi32_i32$2 = $5$hi;
  return $5_1 | 0;
 }
 
 function $69($0_1, $1_1, $1$hi, $2_1, $3_1) {
  $0_1 = $0_1 | 0;
  $1_1 = $1_1 | 0;
  $1$hi = $1$hi | 0;
  $2_1 = $2_1 | 0;
  $3_1 = $3_1 | 0;
  var i64toi32_i32$4 = 0, i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, i64toi32_i32$3 = 0, $12_1 = 0, $4_1 = 0, $6_1 = 0, i64toi32_i32$2 = 0;
  $4_1 = $0_1;
  i64toi32_i32$0 = $1$hi;
  $6_1 = $1_1;
  i64toi32_i32$2 = $1_1;
  i64toi32_i32$1 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$1 = 0;
   $12_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
  } else {
   i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
   $12_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
  }
  return fimport$4($4_1 | 0, $6_1 | 0, $12_1 | 0, $2_1 | 0, $3_1 | 0) | 0 | 0;
 }
 
 function _ZN17compiler_builtins3int3mul3Mul3mul17h070e9a1c69faec5bE(var$0, var$0$hi, var$1, var$1$hi) {
  var$0 = var$0 | 0;
  var$0$hi = var$0$hi | 0;
  var$1 = var$1 | 0;
  var$1$hi = var$1$hi | 0;
  var i64toi32_i32$4 = 0, i64toi32_i32$0 = 0, i64toi32_i32$1 = 0, var$2 = 0, i64toi32_i32$2 = 0, i64toi32_i32$3 = 0, var$3 = 0, var$4 = 0, var$5 = 0, $21_1 = 0, $22_1 = 0, var$6 = 0, $24_1 = 0, $17_1 = 0, $18_1 = 0, $23_1 = 0, $29_1 = 0, $45_1 = 0, $56$hi = 0, $62$hi = 0;
  i64toi32_i32$0 = var$1$hi;
  var$2 = var$1;
  var$4 = var$2 >>> 16 | 0;
  i64toi32_i32$0 = var$0$hi;
  var$3 = var$0;
  var$5 = var$3 >>> 16 | 0;
  $17_1 = Math_imul(var$4, var$5);
  $18_1 = var$2;
  i64toi32_i32$2 = var$3;
  i64toi32_i32$1 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$1 = 0;
   $21_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
  } else {
   i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
   $21_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
  }
  $23_1 = $17_1 + Math_imul($18_1, $21_1) | 0;
  i64toi32_i32$1 = var$1$hi;
  i64toi32_i32$0 = var$1;
  i64toi32_i32$2 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$2 = 0;
   $22_1 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
  } else {
   i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
   $22_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$0 >>> i64toi32_i32$4 | 0) | 0;
  }
  $29_1 = $23_1 + Math_imul($22_1, var$3) | 0;
  var$2 = var$2 & 65535 | 0;
  var$3 = var$3 & 65535 | 0;
  var$6 = Math_imul(var$2, var$3);
  var$2 = (var$6 >>> 16 | 0) + Math_imul(var$2, var$5) | 0;
  $45_1 = $29_1 + (var$2 >>> 16 | 0) | 0;
  var$2 = (var$2 & 65535 | 0) + Math_imul(var$4, var$3) | 0;
  i64toi32_i32$2 = 0;
  i64toi32_i32$1 = $45_1 + (var$2 >>> 16 | 0) | 0;
  i64toi32_i32$0 = 0;
  i64toi32_i32$3 = 32;
  i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
  if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
   i64toi32_i32$0 = i64toi32_i32$1 << i64toi32_i32$4 | 0;
   $24_1 = 0;
  } else {
   i64toi32_i32$0 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$1 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$2 << i64toi32_i32$4 | 0) | 0;
   $24_1 = i64toi32_i32$1 << i64toi32_i32$4 | 0;
  }
  $56$hi = i64toi32_i32$0;
  i64toi32_i32$0 = 0;
  $62$hi = i64toi32_i32$0;
  i64toi32_i32$0 = $56$hi;
  i64toi32_i32$2 = $24_1;
  i64toi32_i32$1 = $62$hi;
  i64toi32_i32$3 = var$2 << 16 | 0 | (var$6 & 65535 | 0) | 0;
  i64toi32_i32$1 = i64toi32_i32$0 | i64toi32_i32$1 | 0;
  i64toi32_i32$2 = i64toi32_i32$2 | i64toi32_i32$3 | 0;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
  return i64toi32_i32$2 | 0;
 }
 
 function _ZN17compiler_builtins3int4udiv10divmod_u6417h6026910b5ed08e40E(var$0, var$0$hi, var$1, var$1$hi) {
  var$0 = var$0 | 0;
  var$0$hi = var$0$hi | 0;
  var$1 = var$1 | 0;
  var$1$hi = var$1$hi | 0;
  var i64toi32_i32$2 = 0, i64toi32_i32$3 = 0, i64toi32_i32$4 = 0, i64toi32_i32$1 = 0, i64toi32_i32$0 = 0, i64toi32_i32$5 = 0, var$2 = 0, var$3 = 0, var$4 = 0, var$5 = 0, var$5$hi = 0, var$6 = 0, var$6$hi = 0, i64toi32_i32$6 = 0, $37_1 = 0, $38_1 = 0, $39_1 = 0, $40_1 = 0, $41_1 = 0, $42_1 = 0, $43_1 = 0, $44_1 = 0, var$8$hi = 0, $45_1 = 0, $46_1 = 0, $47_1 = 0, $48_1 = 0, var$7$hi = 0, $49_1 = 0, $63$hi = 0, $65_1 = 0, $65$hi = 0, $120$hi = 0, $129$hi = 0, $134$hi = 0, var$8 = 0, $140 = 0, $140$hi = 0, $142$hi = 0, $144 = 0, $144$hi = 0, $151 = 0, $151$hi = 0, $154$hi = 0, var$7 = 0, $165$hi = 0;
  label$1 : {
   label$2 : {
    label$3 : {
     label$4 : {
      label$5 : {
       label$6 : {
        label$7 : {
         label$8 : {
          label$9 : {
           label$10 : {
            label$11 : {
             i64toi32_i32$0 = var$0$hi;
             i64toi32_i32$2 = var$0;
             i64toi32_i32$1 = 0;
             i64toi32_i32$3 = 32;
             i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
             if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
              i64toi32_i32$1 = 0;
              $37_1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
             } else {
              i64toi32_i32$1 = i64toi32_i32$0 >>> i64toi32_i32$4 | 0;
              $37_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$0 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
             }
             var$2 = $37_1;
             if (var$2) {
              i64toi32_i32$1 = var$1$hi;
              var$3 = var$1;
              if (!var$3) {
               break label$11
              }
              i64toi32_i32$0 = var$3;
              i64toi32_i32$2 = 0;
              i64toi32_i32$3 = 32;
              i64toi32_i32$4 = i64toi32_i32$3 & 31 | 0;
              if (32 >>> 0 <= (i64toi32_i32$3 & 63 | 0) >>> 0) {
               i64toi32_i32$2 = 0;
               $38_1 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
              } else {
               i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$4 | 0;
               $38_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$0 >>> i64toi32_i32$4 | 0) | 0;
              }
              var$4 = $38_1;
              if (!var$4) {
               break label$9
              }
              var$2 = Math_clz32(var$4) - Math_clz32(var$2) | 0;
              if (var$2 >>> 0 <= 31 >>> 0) {
               break label$8
              }
              break label$2;
             }
             i64toi32_i32$2 = var$1$hi;
             i64toi32_i32$1 = var$1;
             i64toi32_i32$0 = 1;
             i64toi32_i32$3 = 0;
             if (i64toi32_i32$2 >>> 0 > i64toi32_i32$0 >>> 0 | ((i64toi32_i32$2 | 0) == (i64toi32_i32$0 | 0) & i64toi32_i32$1 >>> 0 >= i64toi32_i32$3 >>> 0 | 0) | 0) {
              break label$2
             }
             i64toi32_i32$1 = var$0$hi;
             var$2 = var$0;
             i64toi32_i32$1 = i64toi32_i32$2;
             i64toi32_i32$1 = i64toi32_i32$2;
             var$3 = var$1;
             var$2 = (var$2 >>> 0) / (var$3 >>> 0) | 0;
             i64toi32_i32$1 = 0;
             __wasm_intrinsics_temp_i64 = var$0 - Math_imul(var$2, var$3) | 0;
             __wasm_intrinsics_temp_i64$hi = i64toi32_i32$1;
             i64toi32_i32$1 = 0;
             i64toi32_i32$2 = var$2;
             i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
             return i64toi32_i32$2 | 0;
            }
            i64toi32_i32$2 = var$1$hi;
            i64toi32_i32$3 = var$1;
            i64toi32_i32$1 = 0;
            i64toi32_i32$0 = 32;
            i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
            if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
             i64toi32_i32$1 = 0;
             $39_1 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
            } else {
             i64toi32_i32$1 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
             $39_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$2 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$3 >>> i64toi32_i32$4 | 0) | 0;
            }
            var$3 = $39_1;
            i64toi32_i32$1 = var$0$hi;
            if (!var$0) {
             break label$7
            }
            if (!var$3) {
             break label$6
            }
            var$4 = var$3 + -1 | 0;
            if (var$4 & var$3 | 0) {
             break label$6
            }
            i64toi32_i32$1 = 0;
            i64toi32_i32$2 = var$4 & var$2 | 0;
            i64toi32_i32$3 = 0;
            i64toi32_i32$0 = 32;
            i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
            if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
             i64toi32_i32$3 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
             $40_1 = 0;
            } else {
             i64toi32_i32$3 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$2 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$1 << i64toi32_i32$4 | 0) | 0;
             $40_1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
            }
            $63$hi = i64toi32_i32$3;
            i64toi32_i32$3 = var$0$hi;
            i64toi32_i32$1 = var$0;
            i64toi32_i32$2 = 0;
            i64toi32_i32$0 = -1;
            i64toi32_i32$2 = i64toi32_i32$3 & i64toi32_i32$2 | 0;
            $65_1 = i64toi32_i32$1 & i64toi32_i32$0 | 0;
            $65$hi = i64toi32_i32$2;
            i64toi32_i32$2 = $63$hi;
            i64toi32_i32$3 = $40_1;
            i64toi32_i32$1 = $65$hi;
            i64toi32_i32$0 = $65_1;
            i64toi32_i32$1 = i64toi32_i32$2 | i64toi32_i32$1 | 0;
            __wasm_intrinsics_temp_i64 = i64toi32_i32$3 | i64toi32_i32$0 | 0;
            __wasm_intrinsics_temp_i64$hi = i64toi32_i32$1;
            i64toi32_i32$1 = 0;
            i64toi32_i32$3 = var$2 >>> ((__wasm_ctz_i32(var$3 | 0) | 0) & 31 | 0) | 0;
            i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
            return i64toi32_i32$3 | 0;
           }
          }
          var$4 = var$3 + -1 | 0;
          if (!(var$4 & var$3 | 0)) {
           break label$5
          }
          var$2 = (Math_clz32(var$3) + 33 | 0) - Math_clz32(var$2) | 0;
          var$3 = 0 - var$2 | 0;
          break label$3;
         }
         var$3 = 63 - var$2 | 0;
         var$2 = var$2 + 1 | 0;
         break label$3;
        }
        var$4 = (var$2 >>> 0) / (var$3 >>> 0) | 0;
        i64toi32_i32$3 = 0;
        i64toi32_i32$2 = var$2 - Math_imul(var$4, var$3) | 0;
        i64toi32_i32$1 = 0;
        i64toi32_i32$0 = 32;
        i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
        if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
         i64toi32_i32$1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
         $41_1 = 0;
        } else {
         i64toi32_i32$1 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$2 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$3 << i64toi32_i32$4 | 0) | 0;
         $41_1 = i64toi32_i32$2 << i64toi32_i32$4 | 0;
        }
        __wasm_intrinsics_temp_i64 = $41_1;
        __wasm_intrinsics_temp_i64$hi = i64toi32_i32$1;
        i64toi32_i32$1 = 0;
        i64toi32_i32$2 = var$4;
        i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
        return i64toi32_i32$2 | 0;
       }
       var$2 = Math_clz32(var$3) - Math_clz32(var$2) | 0;
       if (var$2 >>> 0 < 31 >>> 0) {
        break label$4
       }
       break label$2;
      }
      i64toi32_i32$2 = var$0$hi;
      i64toi32_i32$2 = 0;
      __wasm_intrinsics_temp_i64 = var$4 & var$0 | 0;
      __wasm_intrinsics_temp_i64$hi = i64toi32_i32$2;
      if ((var$3 | 0) == (1 | 0)) {
       break label$1
      }
      i64toi32_i32$2 = var$0$hi;
      i64toi32_i32$2 = 0;
      $120$hi = i64toi32_i32$2;
      i64toi32_i32$2 = var$0$hi;
      i64toi32_i32$3 = var$0;
      i64toi32_i32$1 = $120$hi;
      i64toi32_i32$0 = __wasm_ctz_i32(var$3 | 0) | 0;
      i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
      if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
       i64toi32_i32$1 = 0;
       $42_1 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
      } else {
       i64toi32_i32$1 = i64toi32_i32$2 >>> i64toi32_i32$4 | 0;
       $42_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$2 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$3 >>> i64toi32_i32$4 | 0) | 0;
      }
      i64toi32_i32$3 = $42_1;
      i64toi32_i32$HIGH_BITS = i64toi32_i32$1;
      return i64toi32_i32$3 | 0;
     }
     var$3 = 63 - var$2 | 0;
     var$2 = var$2 + 1 | 0;
    }
    i64toi32_i32$3 = var$0$hi;
    i64toi32_i32$3 = 0;
    $129$hi = i64toi32_i32$3;
    i64toi32_i32$3 = var$0$hi;
    i64toi32_i32$2 = var$0;
    i64toi32_i32$1 = $129$hi;
    i64toi32_i32$0 = var$2 & 63 | 0;
    i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
     i64toi32_i32$1 = 0;
     $43_1 = i64toi32_i32$3 >>> i64toi32_i32$4 | 0;
    } else {
     i64toi32_i32$1 = i64toi32_i32$3 >>> i64toi32_i32$4 | 0;
     $43_1 = (((1 << i64toi32_i32$4 | 0) - 1 | 0) & i64toi32_i32$3 | 0) << (32 - i64toi32_i32$4 | 0) | 0 | (i64toi32_i32$2 >>> i64toi32_i32$4 | 0) | 0;
    }
    var$5 = $43_1;
    var$5$hi = i64toi32_i32$1;
    i64toi32_i32$1 = var$0$hi;
    i64toi32_i32$1 = 0;
    $134$hi = i64toi32_i32$1;
    i64toi32_i32$1 = var$0$hi;
    i64toi32_i32$3 = var$0;
    i64toi32_i32$2 = $134$hi;
    i64toi32_i32$0 = var$3 & 63 | 0;
    i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
     i64toi32_i32$2 = i64toi32_i32$3 << i64toi32_i32$4 | 0;
     $44_1 = 0;
    } else {
     i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$3 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$1 << i64toi32_i32$4 | 0) | 0;
     $44_1 = i64toi32_i32$3 << i64toi32_i32$4 | 0;
    }
    var$0 = $44_1;
    var$0$hi = i64toi32_i32$2;
    label$13 : {
     if (var$2) {
      i64toi32_i32$2 = var$1$hi;
      i64toi32_i32$1 = var$1;
      i64toi32_i32$3 = -1;
      i64toi32_i32$0 = -1;
      i64toi32_i32$4 = i64toi32_i32$1 + i64toi32_i32$0 | 0;
      i64toi32_i32$5 = i64toi32_i32$2 + i64toi32_i32$3 | 0;
      if (i64toi32_i32$4 >>> 0 < i64toi32_i32$0 >>> 0) {
       i64toi32_i32$5 = i64toi32_i32$5 + 1 | 0
      }
      var$8 = i64toi32_i32$4;
      var$8$hi = i64toi32_i32$5;
      label$15 : while (1) {
       i64toi32_i32$5 = var$5$hi;
       i64toi32_i32$2 = var$5;
       i64toi32_i32$1 = 0;
       i64toi32_i32$0 = 1;
       i64toi32_i32$3 = i64toi32_i32$0 & 31 | 0;
       if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
        i64toi32_i32$1 = i64toi32_i32$2 << i64toi32_i32$3 | 0;
        $45_1 = 0;
       } else {
        i64toi32_i32$1 = ((1 << i64toi32_i32$3 | 0) - 1 | 0) & (i64toi32_i32$2 >>> (32 - i64toi32_i32$3 | 0) | 0) | 0 | (i64toi32_i32$5 << i64toi32_i32$3 | 0) | 0;
        $45_1 = i64toi32_i32$2 << i64toi32_i32$3 | 0;
       }
       $140 = $45_1;
       $140$hi = i64toi32_i32$1;
       i64toi32_i32$1 = var$0$hi;
       i64toi32_i32$5 = var$0;
       i64toi32_i32$2 = 0;
       i64toi32_i32$0 = 63;
       i64toi32_i32$3 = i64toi32_i32$0 & 31 | 0;
       if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
        i64toi32_i32$2 = 0;
        $46_1 = i64toi32_i32$1 >>> i64toi32_i32$3 | 0;
       } else {
        i64toi32_i32$2 = i64toi32_i32$1 >>> i64toi32_i32$3 | 0;
        $46_1 = (((1 << i64toi32_i32$3 | 0) - 1 | 0) & i64toi32_i32$1 | 0) << (32 - i64toi32_i32$3 | 0) | 0 | (i64toi32_i32$5 >>> i64toi32_i32$3 | 0) | 0;
       }
       $142$hi = i64toi32_i32$2;
       i64toi32_i32$2 = $140$hi;
       i64toi32_i32$1 = $140;
       i64toi32_i32$5 = $142$hi;
       i64toi32_i32$0 = $46_1;
       i64toi32_i32$5 = i64toi32_i32$2 | i64toi32_i32$5 | 0;
       var$5 = i64toi32_i32$1 | i64toi32_i32$0 | 0;
       var$5$hi = i64toi32_i32$5;
       $144 = var$5;
       $144$hi = i64toi32_i32$5;
       i64toi32_i32$5 = var$8$hi;
       i64toi32_i32$5 = var$5$hi;
       i64toi32_i32$5 = var$8$hi;
       i64toi32_i32$2 = var$8;
       i64toi32_i32$1 = var$5$hi;
       i64toi32_i32$0 = var$5;
       i64toi32_i32$3 = i64toi32_i32$2 - i64toi32_i32$0 | 0;
       i64toi32_i32$6 = i64toi32_i32$2 >>> 0 < i64toi32_i32$0 >>> 0;
       i64toi32_i32$4 = i64toi32_i32$6 + i64toi32_i32$1 | 0;
       i64toi32_i32$4 = i64toi32_i32$5 - i64toi32_i32$4 | 0;
       i64toi32_i32$5 = i64toi32_i32$3;
       i64toi32_i32$2 = 0;
       i64toi32_i32$0 = 63;
       i64toi32_i32$1 = i64toi32_i32$0 & 31 | 0;
       if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
        i64toi32_i32$2 = i64toi32_i32$4 >> 31 | 0;
        $47_1 = i64toi32_i32$4 >> i64toi32_i32$1 | 0;
       } else {
        i64toi32_i32$2 = i64toi32_i32$4 >> i64toi32_i32$1 | 0;
        $47_1 = (((1 << i64toi32_i32$1 | 0) - 1 | 0) & i64toi32_i32$4 | 0) << (32 - i64toi32_i32$1 | 0) | 0 | (i64toi32_i32$5 >>> i64toi32_i32$1 | 0) | 0;
       }
       var$6 = $47_1;
       var$6$hi = i64toi32_i32$2;
       i64toi32_i32$2 = var$1$hi;
       i64toi32_i32$2 = var$6$hi;
       i64toi32_i32$4 = var$6;
       i64toi32_i32$5 = var$1$hi;
       i64toi32_i32$0 = var$1;
       i64toi32_i32$5 = i64toi32_i32$2 & i64toi32_i32$5 | 0;
       $151 = i64toi32_i32$4 & i64toi32_i32$0 | 0;
       $151$hi = i64toi32_i32$5;
       i64toi32_i32$5 = $144$hi;
       i64toi32_i32$2 = $144;
       i64toi32_i32$4 = $151$hi;
       i64toi32_i32$0 = $151;
       i64toi32_i32$1 = i64toi32_i32$2 - i64toi32_i32$0 | 0;
       i64toi32_i32$6 = i64toi32_i32$2 >>> 0 < i64toi32_i32$0 >>> 0;
       i64toi32_i32$3 = i64toi32_i32$6 + i64toi32_i32$4 | 0;
       i64toi32_i32$3 = i64toi32_i32$5 - i64toi32_i32$3 | 0;
       var$5 = i64toi32_i32$1;
       var$5$hi = i64toi32_i32$3;
       i64toi32_i32$3 = var$0$hi;
       i64toi32_i32$5 = var$0;
       i64toi32_i32$2 = 0;
       i64toi32_i32$0 = 1;
       i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
       if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
        i64toi32_i32$2 = i64toi32_i32$5 << i64toi32_i32$4 | 0;
        $48_1 = 0;
       } else {
        i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$5 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$3 << i64toi32_i32$4 | 0) | 0;
        $48_1 = i64toi32_i32$5 << i64toi32_i32$4 | 0;
       }
       $154$hi = i64toi32_i32$2;
       i64toi32_i32$2 = var$7$hi;
       i64toi32_i32$2 = $154$hi;
       i64toi32_i32$3 = $48_1;
       i64toi32_i32$5 = var$7$hi;
       i64toi32_i32$0 = var$7;
       i64toi32_i32$5 = i64toi32_i32$2 | i64toi32_i32$5 | 0;
       var$0 = i64toi32_i32$3 | i64toi32_i32$0 | 0;
       var$0$hi = i64toi32_i32$5;
       i64toi32_i32$5 = var$6$hi;
       i64toi32_i32$2 = var$6;
       i64toi32_i32$3 = 0;
       i64toi32_i32$0 = 1;
       i64toi32_i32$3 = i64toi32_i32$5 & i64toi32_i32$3 | 0;
       var$6 = i64toi32_i32$2 & i64toi32_i32$0 | 0;
       var$6$hi = i64toi32_i32$3;
       var$7 = var$6;
       var$7$hi = i64toi32_i32$3;
       var$2 = var$2 + -1 | 0;
       if (var$2) {
        continue label$15
       }
       break label$15;
      };
      break label$13;
     }
    }
    i64toi32_i32$3 = var$5$hi;
    __wasm_intrinsics_temp_i64 = var$5;
    __wasm_intrinsics_temp_i64$hi = i64toi32_i32$3;
    i64toi32_i32$3 = var$0$hi;
    i64toi32_i32$5 = var$0;
    i64toi32_i32$2 = 0;
    i64toi32_i32$0 = 1;
    i64toi32_i32$4 = i64toi32_i32$0 & 31 | 0;
    if (32 >>> 0 <= (i64toi32_i32$0 & 63 | 0) >>> 0) {
     i64toi32_i32$2 = i64toi32_i32$5 << i64toi32_i32$4 | 0;
     $49_1 = 0;
    } else {
     i64toi32_i32$2 = ((1 << i64toi32_i32$4 | 0) - 1 | 0) & (i64toi32_i32$5 >>> (32 - i64toi32_i32$4 | 0) | 0) | 0 | (i64toi32_i32$3 << i64toi32_i32$4 | 0) | 0;
     $49_1 = i64toi32_i32$5 << i64toi32_i32$4 | 0;
    }
    $165$hi = i64toi32_i32$2;
    i64toi32_i32$2 = var$6$hi;
    i64toi32_i32$2 = $165$hi;
    i64toi32_i32$3 = $49_1;
    i64toi32_i32$5 = var$6$hi;
    i64toi32_i32$0 = var$6;
    i64toi32_i32$5 = i64toi32_i32$2 | i64toi32_i32$5 | 0;
    i64toi32_i32$3 = i64toi32_i32$3 | i64toi32_i32$0 | 0;
    i64toi32_i32$HIGH_BITS = i64toi32_i32$5;
    return i64toi32_i32$3 | 0;
   }
   i64toi32_i32$3 = var$0$hi;
   __wasm_intrinsics_temp_i64 = var$0;
   __wasm_intrinsics_temp_i64$hi = i64toi32_i32$3;
   i64toi32_i32$3 = 0;
   var$0 = 0;
   var$0$hi = i64toi32_i32$3;
  }
  i64toi32_i32$3 = var$0$hi;
  i64toi32_i32$5 = var$0;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$3;
  return i64toi32_i32$5 | 0;
 }
 
 function __wasm_ctz_i32(var$0) {
  var$0 = var$0 | 0;
  if (var$0) {
   return 31 - Math_clz32((var$0 + -1 | 0) ^ var$0 | 0) | 0 | 0
  }
  return 32 | 0;
 }
 
 function __wasm_i64_mul(var$0, var$0$hi, var$1, var$1$hi) {
  var$0 = var$0 | 0;
  var$0$hi = var$0$hi | 0;
  var$1 = var$1 | 0;
  var$1$hi = var$1$hi | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0;
  i64toi32_i32$0 = var$0$hi;
  i64toi32_i32$0 = var$1$hi;
  i64toi32_i32$0 = var$0$hi;
  i64toi32_i32$1 = var$1$hi;
  i64toi32_i32$1 = _ZN17compiler_builtins3int3mul3Mul3mul17h070e9a1c69faec5bE(var$0 | 0, i64toi32_i32$0 | 0, var$1 | 0, i64toi32_i32$1 | 0) | 0;
  i64toi32_i32$0 = i64toi32_i32$HIGH_BITS;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$0;
  return i64toi32_i32$1 | 0;
 }
 
 function __wasm_i64_udiv(var$0, var$0$hi, var$1, var$1$hi) {
  var$0 = var$0 | 0;
  var$0$hi = var$0$hi | 0;
  var$1 = var$1 | 0;
  var$1$hi = var$1$hi | 0;
  var i64toi32_i32$0 = 0, i64toi32_i32$1 = 0;
  i64toi32_i32$0 = var$0$hi;
  i64toi32_i32$0 = var$1$hi;
  i64toi32_i32$0 = var$0$hi;
  i64toi32_i32$1 = var$1$hi;
  i64toi32_i32$1 = _ZN17compiler_builtins3int4udiv10divmod_u6417h6026910b5ed08e40E(var$0 | 0, i64toi32_i32$0 | 0, var$1 | 0, i64toi32_i32$1 | 0) | 0;
  i64toi32_i32$0 = i64toi32_i32$HIGH_BITS;
  i64toi32_i32$HIGH_BITS = i64toi32_i32$0;
  return i64toi32_i32$1 | 0;
 }
 
 function __wasm_rotl_i32(var$0, var$1) {
  var$0 = var$0 | 0;
  var$1 = var$1 | 0;
  var var$2 = 0;
  var$2 = var$1 & 31 | 0;
  var$1 = (0 - var$1 | 0) & 31 | 0;
  return ((-1 >>> var$2 | 0) & var$0 | 0) << var$2 | 0 | (((-1 << var$1 | 0) & var$0 | 0) >>> var$1 | 0) | 0 | 0;
 }
 
 // EMSCRIPTEN_END_FUNCS
;
 bufferView = HEAPU8;
 initActiveSegments(imports);
 var FUNCTION_TABLE = Table([null, $5, $4, $6, $32, $33, $44, $46]);
 function __wasm_memory_size() {
  return buffer.byteLength / 65536 | 0;
 }
 
 function __wasm_memory_grow(pagesToAdd) {
  pagesToAdd = pagesToAdd | 0;
  var oldPages = __wasm_memory_size() | 0;
  var newPages = oldPages + pagesToAdd | 0;
  if ((oldPages < newPages) && (newPages < 65536)) {
   var newBuffer = new ArrayBuffer(Math_imul(newPages, 65536));
   var newHEAP8 = new Int8Array(newBuffer);
   newHEAP8.set(HEAP8);
   HEAP8 = new Int8Array(newBuffer);
   HEAP16 = new Int16Array(newBuffer);
   HEAP32 = new Int32Array(newBuffer);
   HEAPU8 = new Uint8Array(newBuffer);
   HEAPU16 = new Uint16Array(newBuffer);
   HEAPU32 = new Uint32Array(newBuffer);
   HEAPF32 = new Float32Array(newBuffer);
   HEAPF64 = new Float64Array(newBuffer);
   buffer = newBuffer;
   bufferView = HEAPU8;
  }
  return oldPages;
 }
 
 return {
  "memory": Object.create(Object.prototype, {
   "grow": {
    "value": __wasm_memory_grow
   }, 
   "buffer": {
    "get": function () {
     return buffer;
    }
    
   }
  }), 
  "__wasm_call_ctors": $0, 
  "main": $2, 
  "__indirect_function_table": FUNCTION_TABLE, 
  "fflush": $61, 
  "strerror": $66, 
  "emscripten_stack_get_end": $55, 
  "emscripten_stack_get_base": $54, 
  "emscripten_stack_init": $52, 
  "emscripten_stack_get_free": $53, 
  "_emscripten_stack_restore": $62, 
  "_emscripten_stack_alloc": $63, 
  "emscripten_stack_get_current": $64, 
  "dynCall_jiji": $68
 };
}

  return asmFunc(info);
}

)(info);
  },

  instantiate: /** @suppress{checkTypes} */ function(binary, info) {
    return {
      then: function(ok) {
        var module = new WebAssembly.Module(binary);
        ok({
          'instance': new WebAssembly.Instance(module, info)
        });
        // Emulate a simple WebAssembly.instantiate(..).then(()=>{}).catch(()=>{}) syntax.
        return { catch: function() {} };
      }
    };
  },

  RuntimeError: Error,

  isWasm2js: true,
};
// end include: wasm2js.js

if (WebAssembly.isWasm2js) {
  // We don't need to actually download a wasm binary, mark it as present but
  // empty.
  wasmBinary = [];
}

if (!globalThis.WebAssembly) {
  err('no native wasm support detected');
}

// Wasm globals

//========================================
// Runtime essentials
//========================================

// whether we are quitting the application. no code should run after this.
// set in exit() and abort()
var ABORT = false;

// set by exit() and abort().  Passed to 'onExit' handler.
// NOTE: This is also used as the process return code code in shell environments
// but only when noExitRuntime is false.
var EXITSTATUS;

// In STRICT mode, we only define assert() when ASSERTIONS is set.  i.e. we
// don't define it at all in release modes.  This matches the behaviour of
// MINIMAL_RUNTIME.
// TODO(sbc): Make this the default even without STRICT enabled.
/** @type {function(*, string=)} */
function assert(condition, text) {
  if (!condition) {
    abort('Assertion failed' + (text ? ': ' + text : ''));
  }
}

// We used to include malloc/free by default in the past. Show a helpful error in
// builds with assertions.
function _malloc() {
  abort('malloc() called but not included in the build - add `_malloc` to EXPORTED_FUNCTIONS');
}
function _free() {
  // Show a helpful error since we used to include free by default in the past.
  abort('free() called but not included in the build - add `_free` to EXPORTED_FUNCTIONS');
}

/**
 * Indicates whether filename is delivered via file protocol (as opposed to http/https)
 * @noinline
 */
var isFileURI = (filename) => filename.startsWith('file://');

// include: runtime_common.js
// include: runtime_stack_check.js
// Initializes the stack cookie. Called at the startup of main and at the startup of each thread in pthreads mode.
function writeStackCookie() {
  var max = _emscripten_stack_get_end();
  assert((max & 3) == 0);
  // If the stack ends at address zero we write our cookies 4 bytes into the
  // stack.  This prevents interference with SAFE_HEAP and ASAN which also
  // monitor writes to address zero.
  if (max == 0) {
    max += 4;
  }
  // The stack grow downwards towards _emscripten_stack_get_end.
  // We write cookies to the final two words in the stack and detect if they are
  // ever overwritten.
  HEAPU32[((max)>>2)] = 0x02135467;
  HEAPU32[(((max)+(4))>>2)] = 0x89BACDFE;
  // Also test the global address 0 for integrity.
  HEAPU32[((0)>>2)] = 1668509029;
}

function checkStackCookie() {
  if (ABORT) return;
  var max = _emscripten_stack_get_end();
  // See writeStackCookie().
  if (max == 0) {
    max += 4;
  }
  var cookie1 = HEAPU32[((max)>>2)];
  var cookie2 = HEAPU32[(((max)+(4))>>2)];
  if (cookie1 != 0x02135467 || cookie2 != 0x89BACDFE) {
    abort(`Stack overflow! Stack cookie has been overwritten at ${ptrToString(max)}, expected hex dwords 0x89BACDFE and 0x2135467, but received ${ptrToString(cookie2)} ${ptrToString(cookie1)}`);
  }
  // Also test the global address 0 for integrity.
  if (HEAPU32[((0)>>2)] != 0x63736d65 /* 'emsc' */) {
    abort('Runtime error: The application has corrupted its heap memory area (address zero)!');
  }
}
// end include: runtime_stack_check.js
// include: runtime_exceptions.js
// end include: runtime_exceptions.js
// include: runtime_debug.js
var runtimeDebug = true; // Switch to false at runtime to disable logging at the right times

// Used by XXXXX_DEBUG settings to output debug messages.
function dbg(...args) {
  if (!runtimeDebug && typeof runtimeDebug != 'undefined') return;
  // TODO(sbc): Make this configurable somehow.  Its not always convenient for
  // logging to show up as warnings.
  console.warn(...args);
}

// Endianness check
(() => {
  var h16 = new Int16Array(1);
  var h8 = new Int8Array(h16.buffer);
  h16[0] = 0x6373;
  if (h8[0] !== 0x73 || h8[1] !== 0x63) abort('Runtime error: expected the system to be little-endian! (Run with -sSUPPORT_BIG_ENDIAN to bypass)');
})();

function consumedModuleProp(prop) {
  if (!Object.getOwnPropertyDescriptor(Module, prop)) {
    Object.defineProperty(Module, prop, {
      configurable: true,
      set() {
        abort(`Attempt to set \`Module.${prop}\` after it has already been processed.  This can happen, for example, when code is injected via '--post-js' rather than '--pre-js'`);

      }
    });
  }
}

function makeInvalidEarlyAccess(name) {
  return () => assert(false, `call to '${name}' via reference taken before Wasm module initialization`);

}

function ignoredModuleProp(prop) {
  if (Object.getOwnPropertyDescriptor(Module, prop)) {
    abort(`\`Module.${prop}\` was supplied but \`${prop}\` not included in INCOMING_MODULE_JS_API`);
  }
}

// forcing the filesystem exports a few things by default
function isExportedByForceFilesystem(name) {
  return name === 'FS_createPath' ||
         name === 'FS_createDataFile' ||
         name === 'FS_createPreloadedFile' ||
         name === 'FS_preloadFile' ||
         name === 'FS_unlink' ||
         name === 'addRunDependency' ||
         // The old FS has some functionality that WasmFS lacks.
         name === 'FS_createLazyFile' ||
         name === 'FS_createDevice' ||
         name === 'removeRunDependency';
}

/**
 * Intercept access to a symbols in the global symbol.  This enables us to give
 * informative warnings/errors when folks attempt to use symbols they did not
 * include in their build, or no symbols that no longer exist.
 *
 * We don't define this in MODULARIZE mode since in that mode emscripten symbols
 * are never placed in the global scope.
 */
function hookGlobalSymbolAccess(sym, func) {
  if (!Object.getOwnPropertyDescriptor(globalThis, sym)) {
    Object.defineProperty(globalThis, sym, {
      configurable: true,
      get() {
        func();
        return undefined;
      }
    });
  }
}

function missingGlobal(sym, msg) {
  hookGlobalSymbolAccess(sym, () => {
    warnOnce(`\`${sym}\` is no longer defined by emscripten. ${msg}`);
  });
}

missingGlobal('buffer', 'Please use HEAP8.buffer or wasmMemory.buffer');
missingGlobal('asm', 'Please use wasmExports instead');

function missingLibrarySymbol(sym) {
  hookGlobalSymbolAccess(sym, () => {
    // Can't `abort()` here because it would break code that does runtime
    // checks.  e.g. `if (typeof SDL === 'undefined')`.
    var msg = `\`${sym}\` is a library symbol and not included by default; add it to your library.js __deps or to DEFAULT_LIBRARY_FUNCS_TO_INCLUDE on the command line`;
    // DEFAULT_LIBRARY_FUNCS_TO_INCLUDE requires the name as it appears in
    // library.js, which means $name for a JS name with no prefix, or name
    // for a JS name like _name.
    var librarySymbol = sym;
    if (!librarySymbol.startsWith('_')) {
      librarySymbol = '$' + sym;
    }
    msg += ` (e.g. -sDEFAULT_LIBRARY_FUNCS_TO_INCLUDE='${librarySymbol}')`;
    if (isExportedByForceFilesystem(sym)) {
      msg += '. Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you';
    }
    warnOnce(msg);
  });

  // Any symbol that is not included from the JS library is also (by definition)
  // not exported on the Module object.
  unexportedRuntimeSymbol(sym);
}

function unexportedRuntimeSymbol(sym) {
  if (!Object.getOwnPropertyDescriptor(Module, sym)) {
    Object.defineProperty(Module, sym, {
      configurable: true,
      get() {
        var msg = `'${sym}' was not exported. add it to EXPORTED_RUNTIME_METHODS (see the Emscripten FAQ)`;
        if (isExportedByForceFilesystem(sym)) {
          msg += '. Alternatively, forcing filesystem support (-sFORCE_FILESYSTEM) can export this for you';
        }
        abort(msg);
      },
    });
  }
}

// end include: runtime_debug.js
// Memory management
var
/** @type {!Int8Array} */
  HEAP8,
/** @type {!Uint8Array} */
  HEAPU8,
/** @type {!Int16Array} */
  HEAP16,
/** @type {!Uint16Array} */
  HEAPU16,
/** @type {!Int32Array} */
  HEAP32,
/** @type {!Uint32Array} */
  HEAPU32,
/** @type {!Float32Array} */
  HEAPF32,
/** @type {!Float64Array} */
  HEAPF64;

var runtimeInitialized = false;



function updateMemoryViews() {
  var b = wasmMemory.buffer;
  HEAP8 = new Int8Array(b);
  HEAP16 = new Int16Array(b);
  HEAPU8 = new Uint8Array(b);
  HEAPU16 = new Uint16Array(b);
  HEAP32 = new Int32Array(b);
  HEAPU32 = new Uint32Array(b);
  HEAPF32 = new Float32Array(b);
  HEAPF64 = new Float64Array(b);
}

// include: memoryprofiler.js
// end include: memoryprofiler.js
// end include: runtime_common.js
assert(globalThis.Int32Array && globalThis.Float64Array && Int32Array.prototype.subarray && Int32Array.prototype.set,
       'JS engine does not provide full typed array support');

function preRun() {
  if (Module['preRun']) {
    if (typeof Module['preRun'] == 'function') Module['preRun'] = [Module['preRun']];
    while (Module['preRun'].length) {
      addOnPreRun(Module['preRun'].shift());
    }
  }
  consumedModuleProp('preRun');
  // Begin ATPRERUNS hooks
  callRuntimeCallbacks(onPreRuns);
  // End ATPRERUNS hooks
}

function initRuntime() {
  assert(!runtimeInitialized);
  runtimeInitialized = true;

  checkStackCookie();

  // No ATINITS hooks

  wasmExports['__wasm_call_ctors']();

  // No ATPOSTCTORS hooks
}

function preMain() {
  checkStackCookie();
  // No ATMAINS hooks
}

function postRun() {
  checkStackCookie();
   // PThreads reuse the runtime from the main thread.

  if (Module['postRun']) {
    if (typeof Module['postRun'] == 'function') Module['postRun'] = [Module['postRun']];
    while (Module['postRun'].length) {
      addOnPostRun(Module['postRun'].shift());
    }
  }
  consumedModuleProp('postRun');

  // Begin ATPOSTRUNS hooks
  callRuntimeCallbacks(onPostRuns);
  // End ATPOSTRUNS hooks
}

/** @param {string|number=} what */
function abort(what) {
  Module['onAbort']?.(what);

  what = 'Aborted(' + what + ')';
  // TODO(sbc): Should we remove printing and leave it up to whoever
  // catches the exception?
  err(what);

  ABORT = true;

  // Use a wasm runtime error, because a JS error might be seen as a foreign
  // exception, which means we'd run destructors on it. We need the error to
  // simply make the program stop.
  // FIXME This approach does not work in Wasm EH because it currently does not assume
  // all RuntimeErrors are from traps; it decides whether a RuntimeError is from
  // a trap or not based on a hidden field within the object. So at the moment
  // we don't have a way of throwing a wasm trap from JS. TODO Make a JS API that
  // allows this in the wasm spec.

  // Suppress closure compiler warning here. Closure compiler's builtin extern
  // definition for WebAssembly.RuntimeError claims it takes no arguments even
  // though it can.
  // TODO(https://github.com/google/closure-compiler/pull/3913): Remove if/when upstream closure gets fixed.
  /** @suppress {checkTypes} */
  var e = new WebAssembly.RuntimeError(what);

  // Throw the error whether or not MODULARIZE is set because abort is used
  // in code paths apart from instantiation where an exception is expected
  // to be thrown when abort is called.
  throw e;
}

// show errors on likely calls to FS when it was not included
var FS = {
  error() {
    abort('Filesystem support (FS) was not included. The problem is that you are using files from JS, but files were not used from C/C++, so filesystem support was not auto-included. You can force-include filesystem support with -sFORCE_FILESYSTEM');
  },
  init() { FS.error() },
  createDataFile() { FS.error() },
  createPreloadedFile() { FS.error() },
  createLazyFile() { FS.error() },
  open() { FS.error() },
  mkdev() { FS.error() },
  registerDevice() { FS.error() },
  analyzePath() { FS.error() },

  ErrnoError() { FS.error() },
};


function createExportWrapper(name, nargs) {
  return (...args) => {
    assert(runtimeInitialized, `native function \`${name}\` called before runtime initialization`);
    var f = wasmExports[name];
    assert(f, `exported native function \`${name}\` not found`);
    // Only assert for too many arguments. Too few can be valid since the missing arguments will be zero filled.
    assert(args.length <= nargs, `native function \`${name}\` called with ${args.length} args but expects ${nargs}`);
    return f(...args);
  };
}

var wasmBinaryFile;

// When building with wasm2js these 3 functions all no-ops.
function findWasmBinary(file) {}
function getBinarySync(file) {}
function getWasmBinary(file) {}

async function instantiateArrayBuffer(binaryFile, imports) {
  try {
    var binary = await getWasmBinary(binaryFile);
    var instance = await WebAssembly.instantiate(binary, imports);
    return instance;
  } catch (reason) {
    err(`failed to asynchronously prepare wasm: ${reason}`);

    // Warn on some common problems.
    if (isFileURI(binaryFile)) {
      err(`warning: Loading from a file URI (${binaryFile}) is not supported in most browsers. See https://emscripten.org/docs/getting_started/FAQ.html#how-do-i-run-a-local-webserver-for-testing-why-does-my-program-stall-in-downloading-or-preparing`);
    }
    abort(reason);
  }
}

async function instantiateAsync(binary, binaryFile, imports) {
  if (!binary
      // Don't use streaming for file:// delivered objects in a webview, fetch them synchronously.
      && !isFileURI(binaryFile)
      // Avoid instantiateStreaming() on Node.js environment for now, as while
      // Node.js v18.1.0 implements it, it does not have a full fetch()
      // implementation yet.
      //
      // Reference:
      //   https://github.com/emscripten-core/emscripten/pull/16917
      && !ENVIRONMENT_IS_NODE
     ) {
    try {
      var response = fetch(binaryFile, { credentials: 'same-origin' });
      var instantiationResult = await WebAssembly.instantiateStreaming(response, imports);
      return instantiationResult;
    } catch (reason) {
      // We expect the most common failure cause to be a bad MIME type for the binary,
      // in which case falling back to ArrayBuffer instantiation should work.
      err(`wasm streaming compile failed: ${reason}`);
      err('falling back to ArrayBuffer instantiation');
      // fall back of instantiateArrayBuffer below
    };
  }
  return instantiateArrayBuffer(binaryFile, imports);
}

function getWasmImports() {
  // prepare imports
  var imports = {
    'env': wasmImports,
    'wasi_snapshot_preview1': wasmImports,
  };
  return imports;
}

// Create the wasm instance.
// Receives the wasm imports, returns the exports.
async function createWasm() {
  // Load the wasm module and create an instance of using native support in the JS engine.
  // handle a generated wasm instance, receiving its exports and
  // performing other necessary setup
  /** @param {WebAssembly.Module=} module*/
  function receiveInstance(instance, module) {
    wasmExports = instance.exports;

    assignWasmExports(wasmExports);

    updateMemoryViews();

    removeRunDependency('wasm-instantiate');
    return wasmExports;
  }
  addRunDependency('wasm-instantiate');

  // Prefer streaming instantiation if available.
  // Async compilation can be confusing when an error on the page overwrites Module
  // (for example, if the order of elements is wrong, and the one defining Module is
  // later), so we save Module and check it later.
  var trueModule = Module;
  function receiveInstantiationResult(result) {
    // 'result' is a ResultObject object which has both the module and instance.
    // receiveInstance() will swap in the exports (to Module.asm) so they can be called
    assert(Module === trueModule, 'the Module object should not be replaced during async compilation - perhaps the order of HTML elements is wrong?');
    trueModule = null;
    // TODO: Due to Closure regression https://github.com/google/closure-compiler/issues/3193, the above line no longer optimizes out down to the following line.
    // When the regression is fixed, can restore the above PTHREADS-enabled path.
    return receiveInstance(result['instance']);
  }

  var info = getWasmImports();

  // User shell pages can write their own Module.instantiateWasm = function(imports, successCallback) callback
  // to manually instantiate the Wasm module themselves. This allows pages to
  // run the instantiation parallel to any other async startup actions they are
  // performing.
  // Also pthreads and wasm workers initialize the wasm instance through this
  // path.
  if (Module['instantiateWasm']) {
    return new Promise((resolve, reject) => {
      try {
        Module['instantiateWasm'](info, (inst, mod) => {
          resolve(receiveInstance(inst, mod));
        });
      } catch(e) {
        err(`Module.instantiateWasm callback failed with error: ${e}`);
        reject(e);
      }
    });
  }

  wasmBinaryFile ??= findWasmBinary();
  var result = await instantiateAsync(wasmBinary, wasmBinaryFile, info);
  var exports = receiveInstantiationResult(result);
  return exports;
}

// Globals used by JS i64 conversions (see makeSetValue)
var tempDouble;
var tempI64;

// end include: preamble.js

// Begin JS library code


  class ExitStatus {
      name = 'ExitStatus';
      constructor(status) {
        this.message = `Program terminated with exit(${status})`;
        this.status = status;
      }
    }

  var callRuntimeCallbacks = (callbacks) => {
      while (callbacks.length > 0) {
        // Pass the module as the first argument.
        callbacks.shift()(Module);
      }
    };
  var onPostRuns = [];
  var addOnPostRun = (cb) => onPostRuns.push(cb);

  var onPreRuns = [];
  var addOnPreRun = (cb) => onPreRuns.push(cb);

  var runDependencies = 0;
  
  
  var dependenciesFulfilled = null;
  
  var runDependencyTracking = {
  };
  
  var runDependencyWatcher = null;
  var removeRunDependency = (id) => {
      runDependencies--;
  
      Module['monitorRunDependencies']?.(runDependencies);
  
      assert(id, 'removeRunDependency requires an ID');
      assert(runDependencyTracking[id]);
      delete runDependencyTracking[id];
      if (runDependencies == 0) {
        if (runDependencyWatcher !== null) {
          clearInterval(runDependencyWatcher);
          runDependencyWatcher = null;
        }
        if (dependenciesFulfilled) {
          var callback = dependenciesFulfilled;
          dependenciesFulfilled = null;
          callback(); // can add another dependenciesFulfilled
        }
      }
    };
  
  
  var addRunDependency = (id) => {
      runDependencies++;
  
      Module['monitorRunDependencies']?.(runDependencies);
  
      assert(id, 'addRunDependency requires an ID')
      assert(!runDependencyTracking[id]);
      runDependencyTracking[id] = 1;
      if (runDependencyWatcher === null && globalThis.setInterval) {
        // Check for missing dependencies every few seconds
        runDependencyWatcher = setInterval(() => {
          if (ABORT) {
            clearInterval(runDependencyWatcher);
            runDependencyWatcher = null;
            return;
          }
          var shown = false;
          for (var dep in runDependencyTracking) {
            if (!shown) {
              shown = true;
              err('still waiting on run dependencies:');
            }
            err(`dependency: ${dep}`);
          }
          if (shown) {
            err('(end of list)');
          }
        }, 10000);
        // Prevent this timer from keeping the runtime alive if nothing
        // else is.
        runDependencyWatcher.unref?.()
      }
    };


  
    /**
     * @param {number} ptr
     * @param {string} type
     */
  function getValue(ptr, type = 'i8') {
    if (type.endsWith('*')) type = '*';
    switch (type) {
      case 'i1': return HEAP8[ptr];
      case 'i8': return HEAP8[ptr];
      case 'i16': return HEAP16[((ptr)>>1)];
      case 'i32': return HEAP32[((ptr)>>2)];
      case 'i64': abort('to do getValue(i64) use WASM_BIGINT');
      case 'float': return HEAPF32[((ptr)>>2)];
      case 'double': return HEAPF64[((ptr)>>3)];
      case '*': return HEAPU32[((ptr)>>2)];
      default: abort(`invalid type for getValue: ${type}`);
    }
  }

  var noExitRuntime = true;

  var ptrToString = (ptr) => {
      assert(typeof ptr === 'number', `ptrToString expects a number, got ${typeof ptr}`);
      // Convert to 32-bit unsigned value
      ptr >>>= 0;
      return '0x' + ptr.toString(16).padStart(8, '0');
    };


  
    /**
     * @param {number} ptr
     * @param {number} value
     * @param {string} type
     */
  function setValue(ptr, value, type = 'i8') {
    if (type.endsWith('*')) type = '*';
    switch (type) {
      case 'i1': HEAP8[ptr] = value; break;
      case 'i8': HEAP8[ptr] = value; break;
      case 'i16': HEAP16[((ptr)>>1)] = value; break;
      case 'i32': HEAP32[((ptr)>>2)] = value; break;
      case 'i64': abort('to do setValue(i64) use WASM_BIGINT');
      case 'float': HEAPF32[((ptr)>>2)] = value; break;
      case 'double': HEAPF64[((ptr)>>3)] = value; break;
      case '*': HEAPU32[((ptr)>>2)] = value; break;
      default: abort(`invalid type for setValue: ${type}`);
    }
  }

  var stackRestore = (val) => __emscripten_stack_restore(val);

  var stackSave = () => _emscripten_stack_get_current();

  var warnOnce = (text) => {
      warnOnce.shown ||= {};
      if (!warnOnce.shown[text]) {
        warnOnce.shown[text] = 1;
        if (ENVIRONMENT_IS_NODE) text = 'warning: ' + text;
        err(text);
      }
    };

  

  var __abort_js = () =>
      abort('native code called abort()');

  var getHeapMax = () =>
      // Stay one Wasm page short of 4GB: while e.g. Chrome is able to allocate
      // full 4GB Wasm memories, the size will wrap back to 0 bytes in Wasm side
      // for any code that deals with heap sizes, which would require special
      // casing all heap size related code to treat 0 specially.
      134217728;
  
  var alignMemory = (size, alignment) => {
      assert(alignment, "alignment argument is required");
      return Math.ceil(size / alignment) * alignment;
    };
  
  var growMemory = (size) => {
      var oldHeapSize = wasmMemory.buffer.byteLength;
      var pages = ((size - oldHeapSize + 65535) / 65536) | 0;
      try {
        // round size grow request up to wasm page size (fixed 64KB per spec)
        wasmMemory.grow(pages); // .grow() takes a delta compared to the previous size
        updateMemoryViews();
        return 1 /*success*/;
      } catch(e) {
        err(`growMemory: Attempted to grow heap from ${oldHeapSize} bytes to ${size} bytes, but got error: ${e}`);
      }
      // implicit 0 return to save code size (caller will cast "undefined" into 0
      // anyhow)
    };
  var _emscripten_resize_heap = (requestedSize) => {
      var oldSize = HEAPU8.length;
      // With CAN_ADDRESS_2GB or MEMORY64, pointers are already unsigned.
      requestedSize >>>= 0;
      // With multithreaded builds, races can happen (another thread might increase the size
      // in between), so return a failure, and let the caller retry.
      assert(requestedSize > oldSize);
  
      // Memory resize rules:
      // 1.  Always increase heap size to at least the requested size, rounded up
      //     to next page multiple.
      // 2a. If MEMORY_GROWTH_LINEAR_STEP == -1, excessively resize the heap
      //     geometrically: increase the heap size according to
      //     MEMORY_GROWTH_GEOMETRIC_STEP factor (default +20%), At most
      //     overreserve by MEMORY_GROWTH_GEOMETRIC_CAP bytes (default 96MB).
      // 2b. If MEMORY_GROWTH_LINEAR_STEP != -1, excessively resize the heap
      //     linearly: increase the heap size by at least
      //     MEMORY_GROWTH_LINEAR_STEP bytes.
      // 3.  Max size for the heap is capped at 2048MB-WASM_PAGE_SIZE, or by
      //     MAXIMUM_MEMORY, or by ASAN limit, depending on which is smallest
      // 4.  If we were unable to allocate as much memory, it may be due to
      //     over-eager decision to excessively reserve due to (3) above.
      //     Hence if an allocation fails, cut down on the amount of excess
      //     growth, in an attempt to succeed to perform a smaller allocation.
  
      // A limit is set for how much we can grow. We should not exceed that
      // (the wasm binary specifies it, so if we tried, we'd fail anyhow).
      var maxHeapSize = getHeapMax();
      if (requestedSize > maxHeapSize) {
        err(`Cannot enlarge memory, requested ${requestedSize} bytes, but the limit is ${maxHeapSize} bytes!`);
        return false;
      }
  
      // Loop through potential heap size increases. If we attempt a too eager
      // reservation that fails, cut down on the attempted size and reserve a
      // smaller bump instead. (max 3 times, chosen somewhat arbitrarily)
      for (var cutDown = 1; cutDown <= 4; cutDown *= 2) {
        var overGrownHeapSize = oldSize * (1 + 0.2 / cutDown); // ensure geometric growth
        // but limit overreserving (default to capping at +96MB overgrowth at most)
        overGrownHeapSize = Math.min(overGrownHeapSize, requestedSize + 100663296 );
  
        var newSize = Math.min(maxHeapSize, alignMemory(Math.max(requestedSize, overGrownHeapSize), 65536));
  
        var replacement = growMemory(newSize);
        if (replacement) {
          err('Warning: Enlarging memory arrays, this is not fast! ' + [oldSize, newSize]);
  
          return true;
        }
      }
      err(`Failed to grow the heap from ${oldSize} bytes to ${newSize} bytes, not enough memory!`);
      return false;
    };

  var UTF8Decoder = globalThis.TextDecoder && new TextDecoder();
  
  var findStringEnd = (heapOrArray, idx, maxBytesToRead, ignoreNul) => {
      var maxIdx = idx + maxBytesToRead;
      if (ignoreNul) return maxIdx;
      // TextDecoder needs to know the byte length in advance, it doesn't stop on
      // null terminator by itself.
      // As a tiny code save trick, compare idx against maxIdx using a negation,
      // so that maxBytesToRead=undefined/NaN means Infinity.
      while (heapOrArray[idx] && !(idx >= maxIdx)) ++idx;
      return idx;
    };
  
  
    /**
     * Given a pointer 'idx' to a null-terminated UTF8-encoded string in the given
     * array that contains uint8 values, returns a copy of that string as a
     * Javascript String object.
     * heapOrArray is either a regular array, or a JavaScript typed array view.
     * @param {number=} idx
     * @param {number=} maxBytesToRead
     * @param {boolean=} ignoreNul - If true, the function will not stop on a NUL character.
     * @return {string}
     */
  var UTF8ArrayToString = (heapOrArray, idx = 0, maxBytesToRead, ignoreNul) => {
  
      var endPtr = findStringEnd(heapOrArray, idx, maxBytesToRead, ignoreNul);
  
      // When using conditional TextDecoder, skip it for short strings as the overhead of the native call is not worth it.
      if (endPtr - idx > 16 && heapOrArray.buffer && UTF8Decoder) {
        return UTF8Decoder.decode(heapOrArray.subarray(idx, endPtr));
      }
      var str = '';
      while (idx < endPtr) {
        // For UTF8 byte structure, see:
        // http://en.wikipedia.org/wiki/UTF-8#Description
        // https://www.ietf.org/rfc/rfc2279.txt
        // https://tools.ietf.org/html/rfc3629
        var u0 = heapOrArray[idx++];
        if (!(u0 & 0x80)) { str += String.fromCharCode(u0); continue; }
        var u1 = heapOrArray[idx++] & 63;
        if ((u0 & 0xE0) == 0xC0) { str += String.fromCharCode(((u0 & 31) << 6) | u1); continue; }
        var u2 = heapOrArray[idx++] & 63;
        if ((u0 & 0xF0) == 0xE0) {
          u0 = ((u0 & 15) << 12) | (u1 << 6) | u2;
        } else {
          if ((u0 & 0xF8) != 0xF0) warnOnce('Invalid UTF-8 leading byte ' + ptrToString(u0) + ' encountered when deserializing a UTF-8 string in wasm memory to a JS string!');
          u0 = ((u0 & 7) << 18) | (u1 << 12) | (u2 << 6) | (heapOrArray[idx++] & 63);
        }
  
        if (u0 < 0x10000) {
          str += String.fromCharCode(u0);
        } else {
          var ch = u0 - 0x10000;
          str += String.fromCharCode(0xD800 | (ch >> 10), 0xDC00 | (ch & 0x3FF));
        }
      }
      return str;
    };
  
    /**
     * Given a pointer 'ptr' to a null-terminated UTF8-encoded string in the
     * emscripten HEAP, returns a copy of that string as a Javascript String object.
     *
     * @param {number} ptr
     * @param {number=} maxBytesToRead - An optional length that specifies the
     *   maximum number of bytes to read. You can omit this parameter to scan the
     *   string until the first 0 byte. If maxBytesToRead is passed, and the string
     *   at [ptr, ptr+maxBytesToReadr[ contains a null byte in the middle, then the
     *   string will cut short at that byte index.
     * @param {boolean=} ignoreNul - If true, the function will not stop on a NUL character.
     * @return {string}
     */
  var UTF8ToString = (ptr, maxBytesToRead, ignoreNul) => {
      assert(typeof ptr == 'number', `UTF8ToString expects a number (got ${typeof ptr})`);
      return ptr ? UTF8ArrayToString(HEAPU8, ptr, maxBytesToRead, ignoreNul) : '';
    };
  var SYSCALLS = {
  varargs:undefined,
  getStr(ptr) {
        var ret = UTF8ToString(ptr);
        return ret;
      },
  };
  var _fd_close = (fd) => {
      abort('fd_close called without SYSCALLS_REQUIRE_FILESYSTEM');
    };

  var convertI32PairToI53Checked = (lo, hi) => {
      assert(lo == (lo >>> 0) || lo == (lo|0)); // lo should either be a i32 or a u32
      assert(hi === (hi|0));                    // hi should be a i32
      return ((hi + 0x200000) >>> 0 < 0x400001 - !!lo) ? (lo >>> 0) + hi * 4294967296 : NaN;
    };
  function _fd_seek(fd,offset_low, offset_high,whence,newOffset) {
    var offset = convertI32PairToI53Checked(offset_low, offset_high);
  
  
      return 70;
    ;
  }

  var printCharBuffers = [null,[],[]];
  
  var printChar = (stream, curr) => {
      var buffer = printCharBuffers[stream];
      assert(buffer);
      if (curr === 0 || curr === 10) {
        (stream === 1 ? out : err)(UTF8ArrayToString(buffer));
        buffer.length = 0;
      } else {
        buffer.push(curr);
      }
    };
  
  var flush_NO_FILESYSTEM = () => {
      // flush anything remaining in the buffers during shutdown
      _fflush(0);
      if (printCharBuffers[1].length) printChar(1, 10);
      if (printCharBuffers[2].length) printChar(2, 10);
    };
  
  
  var _fd_write = (fd, iov, iovcnt, pnum) => {
      // hack to support printf in SYSCALLS_REQUIRE_FILESYSTEM=0
      var num = 0;
      for (var i = 0; i < iovcnt; i++) {
        var ptr = HEAPU32[((iov)>>2)];
        var len = HEAPU32[(((iov)+(4))>>2)];
        iov += 8;
        for (var j = 0; j < len; j++) {
          printChar(fd, HEAPU8[ptr+j]);
        }
        num += len;
      }
      HEAPU32[((pnum)>>2)] = num;
      return 0;
    };

  
  var runtimeKeepaliveCounter = 0;
  var keepRuntimeAlive = () => noExitRuntime || runtimeKeepaliveCounter > 0;
  var _proc_exit = (code) => {
      EXITSTATUS = code;
      if (!keepRuntimeAlive()) {
        Module['onExit']?.(code);
        ABORT = true;
      }
      quit_(code, new ExitStatus(code));
    };
  
  
  /** @param {boolean|number=} implicit */
  var exitJS = (status, implicit) => {
      EXITSTATUS = status;
  
      checkUnflushedContent();
  
      // if exit() was called explicitly, warn the user if the runtime isn't actually being shut down
      if (keepRuntimeAlive() && !implicit) {
        var msg = `program exited (with status: ${status}), but keepRuntimeAlive() is set (counter=${runtimeKeepaliveCounter}) due to an async operation, so halting execution but not exiting the runtime or preventing further async execution (you can use emscripten_force_exit, if you want to force a true shutdown)`;
        err(msg);
      }
  
      _proc_exit(status);
    };

  var handleException = (e) => {
      // Certain exception types we do not treat as errors since they are used for
      // internal control flow.
      // 1. ExitStatus, which is thrown by exit()
      // 2. "unwind", which is thrown by emscripten_unwind_to_js_event_loop() and others
      //    that wish to return to JS event loop.
      if (e instanceof ExitStatus || e == 'unwind') {
        return EXITSTATUS;
      }
      checkStackCookie();
      if (e instanceof WebAssembly.RuntimeError) {
        if (_emscripten_stack_get_current() <= 0) {
          err('Stack overflow detected.  You can try increasing -sSTACK_SIZE (currently set to 65536)');
        }
      }
      quit_(1, e);
    };
// End JS library code

// include: postlibrary.js
// This file is included after the automatically-generated JS library code
// but before the wasm module is created.

{

  // Begin ATMODULES hooks
  if (Module['noExitRuntime']) noExitRuntime = Module['noExitRuntime'];
if (Module['print']) out = Module['print'];
if (Module['printErr']) err = Module['printErr'];
if (Module['wasmBinary']) wasmBinary = Module['wasmBinary'];

Module['FS_createDataFile'] = FS.createDataFile;
Module['FS_createPreloadedFile'] = FS.createPreloadedFile;

  // End ATMODULES hooks

  checkIncomingModuleAPI();

  if (Module['arguments']) arguments_ = Module['arguments'];
  if (Module['thisProgram']) thisProgram = Module['thisProgram'];

  // Assertions on removed incoming Module JS APIs.
  assert(typeof Module['memoryInitializerPrefixURL'] == 'undefined', 'Module.memoryInitializerPrefixURL option was removed, use Module.locateFile instead');
  assert(typeof Module['pthreadMainPrefixURL'] == 'undefined', 'Module.pthreadMainPrefixURL option was removed, use Module.locateFile instead');
  assert(typeof Module['cdInitializerPrefixURL'] == 'undefined', 'Module.cdInitializerPrefixURL option was removed, use Module.locateFile instead');
  assert(typeof Module['filePackagePrefixURL'] == 'undefined', 'Module.filePackagePrefixURL option was removed, use Module.locateFile instead');
  assert(typeof Module['read'] == 'undefined', 'Module.read option was removed');
  assert(typeof Module['readAsync'] == 'undefined', 'Module.readAsync option was removed (modify readAsync in JS)');
  assert(typeof Module['readBinary'] == 'undefined', 'Module.readBinary option was removed (modify readBinary in JS)');
  assert(typeof Module['setWindowTitle'] == 'undefined', 'Module.setWindowTitle option was removed (modify emscripten_set_window_title in JS)');
  assert(typeof Module['TOTAL_MEMORY'] == 'undefined', 'Module.TOTAL_MEMORY has been renamed Module.INITIAL_MEMORY');
  assert(typeof Module['ENVIRONMENT'] == 'undefined', 'Module.ENVIRONMENT has been deprecated. To force the environment, use the ENVIRONMENT compile-time option (for example, -sENVIRONMENT=web or -sENVIRONMENT=node)');
  assert(typeof Module['STACK_SIZE'] == 'undefined', 'STACK_SIZE can no longer be set at runtime.  Use -sSTACK_SIZE at link time')
  // If memory is defined in wasm, the user can't provide it, or set INITIAL_MEMORY
  assert(typeof Module['wasmMemory'] == 'undefined', 'Use of `wasmMemory` detected.  Use -sIMPORTED_MEMORY to define wasmMemory externally');
  assert(typeof Module['INITIAL_MEMORY'] == 'undefined', 'Detected runtime INITIAL_MEMORY setting.  Use -sIMPORTED_MEMORY to define wasmMemory dynamically');

  if (Module['preInit']) {
    if (typeof Module['preInit'] == 'function') Module['preInit'] = [Module['preInit']];
    while (Module['preInit'].length > 0) {
      Module['preInit'].shift()();
    }
  }
  consumedModuleProp('preInit');
}

// Begin runtime exports
  var missingLibrarySymbols = [
  'writeI53ToI64',
  'writeI53ToI64Clamped',
  'writeI53ToI64Signaling',
  'writeI53ToU64Clamped',
  'writeI53ToU64Signaling',
  'readI53FromI64',
  'readI53FromU64',
  'convertI32PairToI53',
  'convertU32PairToI53',
  'stackAlloc',
  'getTempRet0',
  'setTempRet0',
  'createNamedFunction',
  'zeroMemory',
  'withStackSave',
  'strError',
  'inetPton4',
  'inetNtop4',
  'inetPton6',
  'inetNtop6',
  'readSockaddr',
  'writeSockaddr',
  'readEmAsmArgs',
  'jstoi_q',
  'getExecutableName',
  'autoResumeAudioContext',
  'dynCallLegacy',
  'getDynCaller',
  'dynCall',
  'runtimeKeepalivePush',
  'runtimeKeepalivePop',
  'callUserCallback',
  'maybeExit',
  'asyncLoad',
  'asmjsMangle',
  'mmapAlloc',
  'HandleAllocator',
  'getUniqueRunDependency',
  'addOnInit',
  'addOnPostCtor',
  'addOnPreMain',
  'addOnExit',
  'STACK_SIZE',
  'STACK_ALIGN',
  'POINTER_SIZE',
  'ASSERTIONS',
  'ccall',
  'cwrap',
  'getEmptyTableSlot',
  'updateTableMap',
  'getFunctionAddress',
  'addFunction',
  'removeFunction',
  'stringToUTF8Array',
  'stringToUTF8',
  'lengthBytesUTF8',
  'intArrayFromString',
  'intArrayToString',
  'AsciiToString',
  'stringToAscii',
  'UTF16ToString',
  'stringToUTF16',
  'lengthBytesUTF16',
  'UTF32ToString',
  'stringToUTF32',
  'lengthBytesUTF32',
  'stringToNewUTF8',
  'stringToUTF8OnStack',
  'writeArrayToMemory',
  'registerKeyEventCallback',
  'maybeCStringToJsString',
  'findEventTarget',
  'getBoundingClientRect',
  'fillMouseEventData',
  'registerMouseEventCallback',
  'registerWheelEventCallback',
  'registerUiEventCallback',
  'registerFocusEventCallback',
  'fillDeviceOrientationEventData',
  'registerDeviceOrientationEventCallback',
  'fillDeviceMotionEventData',
  'registerDeviceMotionEventCallback',
  'screenOrientation',
  'fillOrientationChangeEventData',
  'registerOrientationChangeEventCallback',
  'fillFullscreenChangeEventData',
  'registerFullscreenChangeEventCallback',
  'JSEvents_requestFullscreen',
  'JSEvents_resizeCanvasForFullscreen',
  'registerRestoreOldStyle',
  'hideEverythingExceptGivenElement',
  'restoreHiddenElements',
  'setLetterbox',
  'softFullscreenResizeWebGLRenderTarget',
  'doRequestFullscreen',
  'fillPointerlockChangeEventData',
  'registerPointerlockChangeEventCallback',
  'registerPointerlockErrorEventCallback',
  'requestPointerLock',
  'fillVisibilityChangeEventData',
  'registerVisibilityChangeEventCallback',
  'registerTouchEventCallback',
  'fillGamepadEventData',
  'registerGamepadEventCallback',
  'registerBeforeUnloadEventCallback',
  'fillBatteryEventData',
  'registerBatteryEventCallback',
  'setCanvasElementSize',
  'getCanvasElementSize',
  'jsStackTrace',
  'getCallstack',
  'convertPCtoSourceLocation',
  'getEnvStrings',
  'checkWasiClock',
  'wasiRightsToMuslOFlags',
  'wasiOFlagsToMuslOFlags',
  'initRandomFill',
  'randomFill',
  'safeSetTimeout',
  'setImmediateWrapped',
  'safeRequestAnimationFrame',
  'clearImmediateWrapped',
  'registerPostMainLoop',
  'registerPreMainLoop',
  'getPromise',
  'makePromise',
  'idsToPromises',
  'makePromiseCallback',
  'ExceptionInfo',
  'findMatchingCatch',
  'Browser_asyncPrepareDataCounter',
  'isLeapYear',
  'ydayFromDate',
  'arraySum',
  'addDays',
  'getSocketFromFD',
  'getSocketAddress',
  'FS_createPreloadedFile',
  'FS_preloadFile',
  'FS_modeStringToFlags',
  'FS_getMode',
  'FS_stdin_getChar',
  'FS_mkdirTree',
  '_setNetworkCallback',
  'heapObjectForWebGLType',
  'toTypedArrayIndex',
  'webgl_enable_ANGLE_instanced_arrays',
  'webgl_enable_OES_vertex_array_object',
  'webgl_enable_WEBGL_draw_buffers',
  'webgl_enable_WEBGL_multi_draw',
  'webgl_enable_EXT_polygon_offset_clamp',
  'webgl_enable_EXT_clip_control',
  'webgl_enable_WEBGL_polygon_mode',
  'emscriptenWebGLGet',
  'computeUnpackAlignedImageSize',
  'colorChannelsInGlTextureFormat',
  'emscriptenWebGLGetTexPixelData',
  'emscriptenWebGLGetUniform',
  'webglGetUniformLocation',
  'webglPrepareUniformLocationsBeforeFirstUse',
  'webglGetLeftBracePos',
  'emscriptenWebGLGetVertexAttrib',
  '__glGetActiveAttribOrUniform',
  'writeGLArray',
  'registerWebGlEventCallback',
  'runAndAbortIfError',
  'ALLOC_NORMAL',
  'ALLOC_STACK',
  'allocate',
  'writeStringToMemory',
  'writeAsciiToMemory',
  'allocateUTF8',
  'allocateUTF8OnStack',
  'demangle',
  'stackTrace',
  'getNativeTypeSize',
];
missingLibrarySymbols.forEach(missingLibrarySymbol)

  var unexportedSymbols = [
  'run',
  'out',
  'err',
  'callMain',
  'abort',
  'wasmExports',
  'HEAPF32',
  'HEAPF64',
  'HEAP8',
  'HEAPU8',
  'HEAP16',
  'HEAPU16',
  'HEAP32',
  'HEAPU32',
  'HEAP64',
  'HEAPU64',
  'writeStackCookie',
  'checkStackCookie',
  'convertI32PairToI53Checked',
  'stackSave',
  'stackRestore',
  'ptrToString',
  'exitJS',
  'getHeapMax',
  'growMemory',
  'ENV',
  'ERRNO_CODES',
  'DNS',
  'Protocols',
  'Sockets',
  'timers',
  'warnOnce',
  'readEmAsmArgsArray',
  'handleException',
  'keepRuntimeAlive',
  'alignMemory',
  'wasmTable',
  'wasmMemory',
  'noExitRuntime',
  'addRunDependency',
  'removeRunDependency',
  'addOnPreRun',
  'addOnPostRun',
  'freeTableIndexes',
  'functionsInTableMap',
  'setValue',
  'getValue',
  'PATH',
  'PATH_FS',
  'UTF8Decoder',
  'UTF8ArrayToString',
  'UTF8ToString',
  'UTF16Decoder',
  'JSEvents',
  'specialHTMLTargets',
  'findCanvasEventTarget',
  'currentFullscreenStrategy',
  'restoreOldWindowedStyle',
  'UNWIND_CACHE',
  'ExitStatus',
  'flush_NO_FILESYSTEM',
  'emSetImmediate',
  'emClearImmediate_deps',
  'emClearImmediate',
  'promiseMap',
  'uncaughtExceptionCount',
  'exceptionLast',
  'exceptionCaught',
  'Browser',
  'requestFullscreen',
  'requestFullScreen',
  'setCanvasSize',
  'getUserMedia',
  'createContext',
  'getPreloadedImageData__data',
  'wget',
  'MONTH_DAYS_REGULAR',
  'MONTH_DAYS_LEAP',
  'MONTH_DAYS_REGULAR_CUMULATIVE',
  'MONTH_DAYS_LEAP_CUMULATIVE',
  'SYSCALLS',
  'preloadPlugins',
  'FS_stdin_getChar_buffer',
  'FS_unlink',
  'FS_createPath',
  'FS_createDevice',
  'FS_readFile',
  'FS',
  'FS_root',
  'FS_mounts',
  'FS_devices',
  'FS_streams',
  'FS_nextInode',
  'FS_nameTable',
  'FS_currentPath',
  'FS_initialized',
  'FS_ignorePermissions',
  'FS_filesystems',
  'FS_syncFSRequests',
  'FS_readFiles',
  'FS_lookupPath',
  'FS_getPath',
  'FS_hashName',
  'FS_hashAddNode',
  'FS_hashRemoveNode',
  'FS_lookupNode',
  'FS_createNode',
  'FS_destroyNode',
  'FS_isRoot',
  'FS_isMountpoint',
  'FS_isFile',
  'FS_isDir',
  'FS_isLink',
  'FS_isChrdev',
  'FS_isBlkdev',
  'FS_isFIFO',
  'FS_isSocket',
  'FS_flagsToPermissionString',
  'FS_nodePermissions',
  'FS_mayLookup',
  'FS_mayCreate',
  'FS_mayDelete',
  'FS_mayOpen',
  'FS_checkOpExists',
  'FS_nextfd',
  'FS_getStreamChecked',
  'FS_getStream',
  'FS_createStream',
  'FS_closeStream',
  'FS_dupStream',
  'FS_doSetAttr',
  'FS_chrdev_stream_ops',
  'FS_major',
  'FS_minor',
  'FS_makedev',
  'FS_registerDevice',
  'FS_getDevice',
  'FS_getMounts',
  'FS_syncfs',
  'FS_mount',
  'FS_unmount',
  'FS_lookup',
  'FS_mknod',
  'FS_statfs',
  'FS_statfsStream',
  'FS_statfsNode',
  'FS_create',
  'FS_mkdir',
  'FS_mkdev',
  'FS_symlink',
  'FS_rename',
  'FS_rmdir',
  'FS_readdir',
  'FS_readlink',
  'FS_stat',
  'FS_fstat',
  'FS_lstat',
  'FS_doChmod',
  'FS_chmod',
  'FS_lchmod',
  'FS_fchmod',
  'FS_doChown',
  'FS_chown',
  'FS_lchown',
  'FS_fchown',
  'FS_doTruncate',
  'FS_truncate',
  'FS_ftruncate',
  'FS_utime',
  'FS_open',
  'FS_close',
  'FS_isClosed',
  'FS_llseek',
  'FS_read',
  'FS_write',
  'FS_mmap',
  'FS_msync',
  'FS_ioctl',
  'FS_writeFile',
  'FS_cwd',
  'FS_chdir',
  'FS_createDefaultDirectories',
  'FS_createDefaultDevices',
  'FS_createSpecialDirectories',
  'FS_createStandardStreams',
  'FS_staticInit',
  'FS_init',
  'FS_quit',
  'FS_findObject',
  'FS_analyzePath',
  'FS_createFile',
  'FS_createDataFile',
  'FS_forceLoadFile',
  'FS_createLazyFile',
  'FS_absolutePath',
  'FS_createFolder',
  'FS_createLink',
  'FS_joinPath',
  'FS_mmapAlloc',
  'FS_standardizePath',
  'MEMFS',
  'TTY',
  'PIPEFS',
  'SOCKFS',
  'tempFixedLengthArray',
  'miniTempWebGLFloatBuffers',
  'miniTempWebGLIntBuffers',
  'GL',
  'AL',
  'GLUT',
  'EGL',
  'GLEW',
  'IDBStore',
  'SDL',
  'SDL_gfx',
  'print',
  'printErr',
  'jstoi_s',
];
unexportedSymbols.forEach(unexportedRuntimeSymbol);

  // End runtime exports
  // Begin JS library exports
  // End JS library exports

// end include: postlibrary.js

function checkIncomingModuleAPI() {
  ignoredModuleProp('fetchSettings');
}

// Imports from the Wasm binary.
var _main = Module['_main'] = makeInvalidEarlyAccess('_main');
var _fflush = makeInvalidEarlyAccess('_fflush');
var _strerror = makeInvalidEarlyAccess('_strerror');
var _emscripten_stack_get_end = makeInvalidEarlyAccess('_emscripten_stack_get_end');
var _emscripten_stack_get_base = makeInvalidEarlyAccess('_emscripten_stack_get_base');
var _emscripten_stack_init = makeInvalidEarlyAccess('_emscripten_stack_init');
var _emscripten_stack_get_free = makeInvalidEarlyAccess('_emscripten_stack_get_free');
var __emscripten_stack_restore = makeInvalidEarlyAccess('__emscripten_stack_restore');
var __emscripten_stack_alloc = makeInvalidEarlyAccess('__emscripten_stack_alloc');
var _emscripten_stack_get_current = makeInvalidEarlyAccess('_emscripten_stack_get_current');
var dynCall_jiji = makeInvalidEarlyAccess('dynCall_jiji');
var memory = makeInvalidEarlyAccess('memory');
var __indirect_function_table = makeInvalidEarlyAccess('__indirect_function_table');
var wasmMemory = makeInvalidEarlyAccess('wasmMemory');

function assignWasmExports(wasmExports) {
  assert(typeof wasmExports['main'] != 'undefined', 'missing Wasm export: main');
  assert(typeof wasmExports['fflush'] != 'undefined', 'missing Wasm export: fflush');
  assert(typeof wasmExports['strerror'] != 'undefined', 'missing Wasm export: strerror');
  assert(typeof wasmExports['emscripten_stack_get_end'] != 'undefined', 'missing Wasm export: emscripten_stack_get_end');
  assert(typeof wasmExports['emscripten_stack_get_base'] != 'undefined', 'missing Wasm export: emscripten_stack_get_base');
  assert(typeof wasmExports['emscripten_stack_init'] != 'undefined', 'missing Wasm export: emscripten_stack_init');
  assert(typeof wasmExports['emscripten_stack_get_free'] != 'undefined', 'missing Wasm export: emscripten_stack_get_free');
  assert(typeof wasmExports['_emscripten_stack_restore'] != 'undefined', 'missing Wasm export: _emscripten_stack_restore');
  assert(typeof wasmExports['_emscripten_stack_alloc'] != 'undefined', 'missing Wasm export: _emscripten_stack_alloc');
  assert(typeof wasmExports['emscripten_stack_get_current'] != 'undefined', 'missing Wasm export: emscripten_stack_get_current');
  assert(typeof wasmExports['dynCall_jiji'] != 'undefined', 'missing Wasm export: dynCall_jiji');
  assert(typeof wasmExports['memory'] != 'undefined', 'missing Wasm export: memory');
  assert(typeof wasmExports['__indirect_function_table'] != 'undefined', 'missing Wasm export: __indirect_function_table');
  _main = Module['_main'] = createExportWrapper('main', 2);
  _fflush = createExportWrapper('fflush', 1);
  _strerror = createExportWrapper('strerror', 1);
  _emscripten_stack_get_end = wasmExports['emscripten_stack_get_end'];
  _emscripten_stack_get_base = wasmExports['emscripten_stack_get_base'];
  _emscripten_stack_init = wasmExports['emscripten_stack_init'];
  _emscripten_stack_get_free = wasmExports['emscripten_stack_get_free'];
  __emscripten_stack_restore = wasmExports['_emscripten_stack_restore'];
  __emscripten_stack_alloc = wasmExports['_emscripten_stack_alloc'];
  _emscripten_stack_get_current = wasmExports['emscripten_stack_get_current'];
  dynCall_jiji = createExportWrapper('dynCall_jiji', 5);
  memory = wasmMemory = wasmExports['memory'];
  __indirect_function_table = wasmExports['__indirect_function_table'];
}

var wasmImports = {
  /** @export */
  _abort_js: __abort_js,
  /** @export */
  emscripten_resize_heap: _emscripten_resize_heap,
  /** @export */
  fd_close: _fd_close,
  /** @export */
  fd_seek: _fd_seek,
  /** @export */
  fd_write: _fd_write
};


// include: postamble.js
// === Auto-generated postamble setup entry stuff ===

var calledRun;

function callMain() {
  assert(runDependencies == 0, 'cannot call main when async dependencies remain! (listen on Module["onRuntimeInitialized"])');
  assert(typeof onPreRuns === 'undefined' || onPreRuns.length == 0, 'cannot call main when preRun functions remain to be called');

  var entryFunction = _main;

  var argc = 0;
  var argv = 0;

  try {

    var ret = entryFunction(argc, argv);

    // if we're not running an evented main loop, it's time to exit
    exitJS(ret, /* implicit = */ true);
    return ret;
  } catch (e) {
    return handleException(e);
  }
}

function stackCheckInit() {
  // This is normally called automatically during __wasm_call_ctors but need to
  // get these values before even running any of the ctors so we call it redundantly
  // here.
  _emscripten_stack_init();
  // TODO(sbc): Move writeStackCookie to native to to avoid this.
  writeStackCookie();
}

function run() {

  if (runDependencies > 0) {
    dependenciesFulfilled = run;
    return;
  }

  stackCheckInit();

  preRun();

  // a preRun added a dependency, run will be called later
  if (runDependencies > 0) {
    dependenciesFulfilled = run;
    return;
  }

  function doRun() {
    // run may have just been called through dependencies being fulfilled just in this very frame,
    // or while the async setStatus time below was happening
    assert(!calledRun);
    calledRun = true;
    Module['calledRun'] = true;

    if (ABORT) return;

    initRuntime();

    preMain();

    Module['onRuntimeInitialized']?.();
    consumedModuleProp('onRuntimeInitialized');

    var noInitialRun = Module['noInitialRun'] || false;
    if (!noInitialRun) callMain();

    postRun();
  }

  if (Module['setStatus']) {
    Module['setStatus']('Running...');
    setTimeout(() => {
      setTimeout(() => Module['setStatus'](''), 1);
      doRun();
    }, 1);
  } else
  {
    doRun();
  }
  checkStackCookie();
}

function checkUnflushedContent() {
  // Compiler settings do not allow exiting the runtime, so flushing
  // the streams is not possible. but in ASSERTIONS mode we check
  // if there was something to flush, and if so tell the user they
  // should request that the runtime be exitable.
  // Normally we would not even include flush() at all, but in ASSERTIONS
  // builds we do so just for this check, and here we see if there is any
  // content to flush, that is, we check if there would have been
  // something a non-ASSERTIONS build would have not seen.
  // How we flush the streams depends on whether we are in SYSCALLS_REQUIRE_FILESYSTEM=0
  // mode (which has its own special function for this; otherwise, all
  // the code is inside libc)
  var oldOut = out;
  var oldErr = err;
  var has = false;
  out = err = (x) => {
    has = true;
  }
  try { // it doesn't matter if it fails
    flush_NO_FILESYSTEM();
  } catch(e) {}
  out = oldOut;
  err = oldErr;
  if (has) {
    warnOnce('stdio streams had content in them that was not flushed. you should set EXIT_RUNTIME to 1 (see the Emscripten FAQ), or make sure to emit a newline when you printf etc.');
    warnOnce('(this may also be due to not including full filesystem support - try building with -sFORCE_FILESYSTEM)');
  }
}

var wasmExports;

// With async instantation wasmExports is assigned asynchronously when the
// instance is received.
createWasm();

run();

// end include: postamble.js

