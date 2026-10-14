// Practice site behaviour: check required fields, then move to the next page.
function go(next) {
  var missing = [];
  document.querySelectorAll('[required]').forEach(function (el) {
    var empty = el.type === 'checkbox' ? !el.checked : !el.value;
    if (el.type === 'radio') {
      empty = !document.querySelector('input[name="' + el.name + '"]:checked');
    }
    if (empty) missing.push(el.getAttribute('data-name') || el.name);
  });
  // Fields managed like a modern framework: the page trusts its own copy, not the box.
  (window.controlled || []).forEach(function (c) { if (!c.state) missing.push(c.name); });
  var box = document.getElementById('problems');
  if (missing.length) {
    box.textContent = 'Please complete: ' + missing.filter(function (m, i) { return missing.indexOf(m) === i; }).join(', ');
    box.style.display = 'block';
    return false;
  }
  sessionStorage.setItem('reached', next);
  location.href = next;
  return false;
}
// A "controlled" input: a value set without the right events is thrown away.
function control(id, name) {
  var el = document.getElementById(id);
  var c = { name: name, state: '' };
  el.addEventListener('input', function () { c.state = el.value; });
  setInterval(function () { if (el.value !== c.state) el.value = c.state; }, 80);
  (window.controlled = window.controlled || []).push(c);
}
