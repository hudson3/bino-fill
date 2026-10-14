import Foundation

/// JavaScript that Bino runs inside the page. It only reads the form's structure and
/// sets values it is handed; every decision is made outside the page.
enum PageScript {
    /// Installs `window.__bino`. Safe to run more than once.
    static let install = #"""
(function () {
  if (window.__bino && window.__bino.v === 7) return 'ok';
  var B = { v: 7, seq: 0, els: {} };
  var J = JSON.stringify;

  function clean(s, max) {
    s = (s || '').replace(/\s+/g, ' ').trim();
    return max && s.length > max ? s.slice(0, max) : s;
  }
  function styleOf(el) {
    var w = el.ownerDocument.defaultView;
    return w ? w.getComputedStyle(el) : null;
  }
  function visible(el) {
    if (!el || !el.getClientRects || el.getClientRects().length === 0) return false;
    var s = styleOf(el);
    if (!s || s.visibility === 'hidden' || s.display === 'none') return false;
    var r = el.getBoundingClientRect();
    return r.width > 1 && r.height > 1;
  }
  // Custom-styled radios and checkboxes hide the real input and draw their own box.
  function visibleChoice(el) {
    if (visible(el)) return true;
    var lab = el.labels && el.labels[0];
    if (lab && visible(lab)) return true;
    return !!(el.parentElement && visible(el.parentElement));
  }
  function textOf(node, max) {
    if (!node) return '';
    return clean(node.innerText !== undefined ? node.innerText : node.textContent, max);
  }
  function byIds(el, ids) {
    var out = [];
    (ids || '').split(/\s+/).forEach(function (id) {
      if (!id) return;
      var n = el.ownerDocument.getElementById(id);
      if (n) out.push(textOf(n, 120));
    });
    return clean(out.join(' '), 150);
  }
  function labelTextWithoutControls(lab) {
    var clone = lab.cloneNode(true);
    var drop = clone.querySelectorAll('input,select,textarea,button,option,script,style');
    for (var i = 0; i < drop.length; i++) drop[i].remove();
    return clean(clone.textContent, 150);
  }
  function nearbyText(el) {
    var node = el;
    for (var up = 0; up < 3 && node; up++) {
      var prev = node.previousSibling;
      for (var hops = 0; prev && hops < 4; hops++) {
        var t = prev.nodeType === 3 ? clean(prev.textContent, 100)
          : (prev.nodeType === 1 && !/^(INPUT|SELECT|TEXTAREA|BUTTON|SCRIPT|STYLE)$/.test(prev.tagName)
             && !prev.querySelector('input,select,textarea') ? textOf(prev, 100) : '');
        if (t) return t;
        prev = prev.previousSibling;
      }
      node = node.parentElement;
      if (node && /^(FORM|BODY|FIELDSET|TABLE)$/.test(node.tagName)) break;
    }
    return '';
  }
  function labelFor(el) {
    var t = byIds(el, el.getAttribute('aria-labelledby'));
    if (t) return t;
    if (el.labels && el.labels.length) {
      t = labelTextWithoutControls(el.labels[0]);
      if (t) return t;
    }
    t = clean(el.getAttribute('aria-label'), 150);
    if (t) return t;
    t = clean(el.getAttribute('title'), 150);
    if (t) return t;
    return nearbyText(el);
  }
  // The heading of the nearest labelled group around a field: a radio group's own
  // caption beats the fieldset it sits in.
  function legendFor(el) {
    var node = el.parentElement;
    while (node && node.tagName !== 'FORM' && node.tagName !== 'BODY') {
      var role = node.getAttribute('role');
      if (role === 'group' || role === 'radiogroup') {
        var t = byIds(node, node.getAttribute('aria-labelledby')) || clean(node.getAttribute('aria-label'), 100);
        if (t) return t;
      }
      if (node.tagName === 'FIELDSET') {
        var lg = node.querySelector('legend');
        if (lg) return textOf(lg, 100);
      }
      node = node.parentElement;
    }
    return '';
  }
  function tag(el) {
    var id = el.getAttribute('data-bino');
    if (!id || B.els[id] !== el) {
      id = String(++B.seq);
      el.setAttribute('data-bino', id);
      B.els[id] = el;
    }
    return id;
  }
  B.get = function (id) {
    var el = B.els[id];
    return el && el.isConnected ? el : null;
  };

  // Walks the page in reading order, through open shadow roots and same-origin frames.
  // `origin` is the host of the frame being walked ('' for the page itself).
  var frameCount = 0;
  function hostOf(doc) {
    try { return doc.location && doc.location.host ? doc.location.host : ''; } catch (e) { return ''; }
  }
  // The host a frame element loads from, by its src: '' when it has none or it is this page's own.
  function foreignHost(el) {
    var src = el.getAttribute('src') || '';
    if (!src || /^(about:|javascript:)/i.test(src)) return '';
    var host = '';
    try { host = new URL(src, location.href).host; } catch (e) { return ''; }
    return host && host !== location.host ? host : '';
  }
  // A frame from another host is never readable, whatever contentDocument says: before it
  // loads (or when it fails to), the empty page in it is not the form.
  function readableDocument(el) {
    if (foreignHost(el)) return null;
    try { return el.contentDocument; } catch (e) { return null; }
  }
  function walk(root, frameIndex, visit, origin) {
    if (origin === undefined) origin = '';
    var tw = root.ownerDocument ? root.ownerDocument.createTreeWalker(root, 1) : root.createTreeWalker(root, 1);
    var node = tw.currentNode;
    while (node) {
      if (node.nodeType === 1) {
        visit(node, frameIndex, origin);
        if (node.shadowRoot) walk(node.shadowRoot, frameIndex, visit, origin);
        if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
          var doc = readableDocument(node);
          if (doc && doc.body) {
            // Only tell a frame's boxes apart from the page's when they come from another host.
            var inner = hostOf(doc);
            walk(doc.body, ++frameCount, visit, inner === hostOf(document) ? origin : inner);
          }
        }
      }
      node = tw.nextNode();
    }
  }

  var SKIP_INPUT = /^(hidden|submit|button|image|reset|file)$/;
  var PAY_FRAME = /stripe|braintree|adyen|spreedly|recurly|cybersource|checkout\.com|paypal|worldpay|securepay|cardinal|payment|hosted-?field|card/i;
  var CAPTCHA_FRAME = /recaptcha|hcaptcha|turnstile|arkoselabs|funcaptcha|captcha/i;

  B.scan = function () {
    var fields = [], buttons = [], frames = [], errors = [], radios = {}, heading = '', headings = [];
    var captcha = false;
    frameCount = 0;
    walk(document.body, 0, function (el, frameIndex, origin) {
      var name = el.tagName;
      if (/^H[1-6]$/.test(name) || name === 'LEGEND' || el.getAttribute('role') === 'heading') {
        if (visible(el)) { var h = textOf(el, 100); if (h) { heading = h; if (headings.length < 40) headings.push(h); } }
        return;
      }
      if (name === 'IFRAME' || name === 'FRAME') {
        var reachable = !!readableDocument(el);
        var src = el.getAttribute('src') || '';
        var title = clean(el.getAttribute('title') || el.getAttribute('name') || '', 80);
        if (CAPTCHA_FRAME.test(src + ' ' + title) && !/size=invisible/.test(src) && visible(el)) {
          var cr = el.getBoundingClientRect();
          if (cr.width > 120 && cr.height > 40) captcha = true;
        }
        if (!reachable && visible(el)) {
          var host = '';
          try { host = new URL(src, location.href).host; } catch (e) { host = ''; }
          frames.push({ host: host, title: title, payment: PAY_FRAME.test(src + ' ' + title), section: heading, loading: false });
        }
        return;
      }
      if (name === 'INPUT' || name === 'SELECT' || name === 'TEXTAREA') {
        var type = name === 'INPUT' ? (el.getAttribute('type') || 'text').toLowerCase()
          : (name === 'SELECT' ? 'select' : 'textarea');
        if (SKIP_INPUT.test(type) || el.disabled) return;
        var choice = type === 'radio' || type === 'checkbox';
        if (choice ? !visibleChoice(el) : !visible(el)) return;
        if (/captcha/i.test((el.name || '') + ' ' + (el.id || ''))) { captcha = true; }
        var legend = legendFor(el);
        if (type === 'radio') {
          var key = frameIndex + '|' + (el.form ? tag(el.form) : '-') + '|' + (el.name || tag(el));
          var g = radios[key];
          if (!g) {
            g = { id: 'r' + tag(el), tag: 'input', type: 'radio', name: el.name || '', domId: '', autocomplete: '',
                  placeholder: '', label: legend || nearbyText(el.closest('label') || el), section: legend ? heading : heading,
                  required: false, maxLength: 0, pattern: '', hasValue: false, current: '', options: [],
                  frame: frameIndex, readOnly: false, origin: origin };
            radios[key] = g; fields.push(g);
          }
          var rl = el.labels && el.labels.length ? labelTextWithoutControls(el.labels[0])
            : (clean(el.getAttribute('aria-label'), 80) || nearbyText(el));
          g.options.push({ t: rl || el.value || '', v: el.value || '', id: tag(el) });
          if (el.checked) { g.hasValue = true; g.current = rl || el.value || ''; }
          if (el.required) g.required = true;
          return;
        }
        var f = {
          id: tag(el), tag: name.toLowerCase(), type: type, name: el.getAttribute('name') || '',
          domId: el.id || '', autocomplete: (el.getAttribute('autocomplete') || '').toLowerCase(),
          placeholder: clean(el.getAttribute('placeholder'), 80), label: labelFor(el),
          section: legend || heading, required: !!el.required || el.getAttribute('aria-required') === 'true',
          maxLength: el.maxLength > 0 && el.maxLength < 10000 ? el.maxLength : 0,
          pattern: el.getAttribute('pattern') || '', hasValue: false, current: '', options: [],
          frame: frameIndex, readOnly: !!el.readOnly, origin: origin
        };
        if (type === 'checkbox') {
          f.hasValue = !!el.checked;
        } else if (name === 'SELECT') {
          var opts = el.options;
          for (var i = 0; i < opts.length && i < 400; i++) {
            f.options.push({ t: clean(opts[i].text, 60), v: String(opts[i].value).slice(0, 60), id: String(i) });
          }
          var sel = el.selectedIndex >= 0 ? opts[el.selectedIndex] : null;
          f.current = sel ? clean(sel.text, 60) : '';
          f.hasValue = !!(sel && sel.value !== '' && el.selectedIndex > 0);
        } else {
          // Only whether something is there. Typed values never leave the page.
          f.hasValue = (el.value || '').length > 0;
        }
        fields.push(f);
        return;
      }
      var role = el.getAttribute('role');
      var isButton = name === 'BUTTON' || role === 'button' ||
        (name === 'A' && /\b(btn|button|cta)\b/i.test(el.className && el.className.baseVal === undefined ? el.className : ''));
      if (name === 'INPUT') return;
      if (isButton && visible(el)) {
        var label = textOf(el, 80) || clean(el.getAttribute('aria-label'), 80) || clean(el.getAttribute('title'), 80);
        var r = el.getBoundingClientRect();
        buttons.push({
          id: tag(el), tag: name.toLowerCase(), type: (el.getAttribute('type') || '').toLowerCase(), text: label,
          disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
          inForm: !!(el.form || (el.closest && el.closest('form'))),
          primary: /primary|cta|submit|continue|next/i.test(String(el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || '')),
          y: Math.round(r.top + (el.ownerDocument.defaultView ? el.ownerDocument.defaultView.scrollY : 0)),
          frame: frameIndex, origin: origin
        });
      }
    });
    // Submit-type inputs are buttons too.
    frameCount = 0;
    walk(document.body, 0, function (el, frameIndex, origin) {
      if (el.tagName !== 'INPUT') return;
      var type = (el.getAttribute('type') || '').toLowerCase();
      if (!/^(submit|button|image)$/.test(type) || !visible(el)) return;
      var r = el.getBoundingClientRect();
      buttons.push({
        id: tag(el), tag: 'input', type: type,
        text: clean(el.value || el.getAttribute('alt') || el.getAttribute('aria-label') || (type === 'submit' ? 'Submit' : ''), 80),
        disabled: !!el.disabled, inForm: !!el.form,
        primary: /primary|cta|submit|continue|next/i.test((el.className || '') + ' ' + (el.id || '')),
        y: Math.round(r.top + window.scrollY), frame: frameIndex, origin: origin
      });
    });
    var seen = {};
    var errSel = '[aria-invalid="true"],[role="alert"],.error,.errors,.invalid-feedback,.field-error,.error-message,.form-error,.validation-error,[class*="error-msg"],[class*="errorMessage"]';
    var errNodes = document.querySelectorAll(errSel);
    for (var e = 0; e < errNodes.length && errors.length < 12; e++) {
      var n = errNodes[e];
      if (!visible(n)) continue;
      var et = /^(INPUT|SELECT|TEXTAREA)$/.test(n.tagName)
        ? 'Problem with: ' + (labelFor(n) || n.getAttribute('name') || 'a field') : textOf(n, 160);
      if (et && !seen[et]) { seen[et] = 1; errors.push(et); }
    }
    return J({
      url: location.href, title: clean(document.title, 120), fields: fields, buttons: buttons,
      frames: frames, errors: errors, captcha: captcha, signature: B.signature(), headings: headings
    });
  };

  // Plain links whose wording matches, e.g. a "Sign in" link in a page header. The scan
  // leaves ordinary links out; this is asked for only when signing in.
  B.links = function (pattern) {
    var rx = new RegExp(pattern, 'i'), out = [];
    walk(document.body, 0, function (el) {
      if (out.length >= 20 || el.tagName !== 'A' || !visible(el)) return;
      var label = textOf(el, 60) || clean(el.getAttribute('aria-label'), 60) || clean(el.getAttribute('title'), 60);
      if (label && label.length <= 40 && rx.test(label)) out.push({ id: tag(el), text: label });
    });
    return J(out);
  };

  // Changes when the visible step changes, even if the address does not. Looks into
  // shadow roots and same-origin frames like the scan does, so a form that lives there
  // changes the signature too.
  B.signature = function () {
    var parts = [location.href];
    var count = 0;
    frameCount = 0;
    walk(document.body, 0, function (n) {
      if (count >= 60) return;
      var t = n.tagName;
      if (!/^(INPUT|SELECT|TEXTAREA|H1|H2)$/.test(t)) return;
      if (n.type === 'hidden' || !visible(n)) return;
      count++;
      parts.push(/^H/.test(t) ? textOf(n, 40) : (n.getAttribute('name') || n.id || t));
    });
    var s = parts.join('|'), h = 0;
    for (var k = 0; k < s.length; k++) { h = ((h << 5) - h + s.charCodeAt(k)) | 0; }
    return location.href + '#' + count + '#' + h;
  };

  function fire(el, type) {
    var W = el.ownerDocument.defaultView || window;
    el.dispatchEvent(new W.Event(type, { bubbles: true }));
  }
  function same(a, b) {
    var n = function (s) { return String(s).toLowerCase().replace(/[^a-z0-9]/g, ''); };
    return n(a) === n(b);
  }

  B.fill = function (id, value) {
    var el = B.get(id);
    if (!el) return J({ ok: false, why: 'field is no longer on the page' });
    var W = el.ownerDocument.defaultView || window;
    try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
    try { el.focus(); } catch (e) {}
    var proto = el.tagName === 'TEXTAREA' ? W.HTMLTextAreaElement.prototype : W.HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    fire(el, 'input'); fire(el, 'change');
    try { el.blur(); } catch (e) {}
    var kept = same(el.value, value);
    // Some fields cut the value short or reject it; say so rather than assume.
    return J({ ok: kept, why: kept ? '' : ((el.value || '').length === 0 ? 'the page cleared the value' : 'the page changed the value') });
  };

  B.pick = function (id, optionId) {
    if (id.charAt(0) === 'r') {
      var radio = B.get(optionId);
      if (!radio) return J({ ok: false, why: 'option is no longer on the page' });
      radio.click();
      return J({ ok: !!radio.checked, why: radio.checked ? '' : 'the option did not stay selected' });
    }
    var el = B.get(id);
    if (!el) return J({ ok: false, why: 'field is no longer on the page' });
    var W = el.ownerDocument.defaultView || window;
    var index = parseInt(optionId, 10);
    if (!(index >= 0 && index < el.options.length)) return J({ ok: false, why: 'no such option' });
    var desc = Object.getOwnPropertyDescriptor(W.HTMLSelectElement.prototype, 'value');
    if (desc && desc.set) desc.set.call(el, el.options[index].value); else el.value = el.options[index].value;
    if (el.selectedIndex !== index) el.selectedIndex = index;
    fire(el, 'input'); fire(el, 'change');
    return J({ ok: el.selectedIndex === index, why: el.selectedIndex === index ? '' : 'the option did not stay selected' });
  };

  // Puts the keyboard in a box and leaves it there, for a code only the person can type.
  B.focus = function (id) {
    var el = B.get(id);
    if (!el) return J({ ok: false, why: 'field is no longer on the page' });
    try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
    try { el.focus(); } catch (e) {}
    var doc = el.ownerDocument, active = doc.activeElement;
    // Inside a shadow root the document's active element is the host.
    var ok = active === el || (el.getRootNode && el.getRootNode().activeElement === el);
    return J({ ok: ok, why: ok ? '' : 'the box did not take the keyboard' });
  };

  B.click = function (id) {
    var el = B.get(id);
    if (!el) return J({ ok: false, why: 'button is no longer on the page' });
    try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
    el.click();
    return J({ ok: true, why: '' });
  };

  window.__bino = B;
  return 'ok';
})()
"""#

    static func quote(_ s: String) -> String {
        // JSON string literals are valid JavaScript string literals.
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
