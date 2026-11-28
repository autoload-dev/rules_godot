// The page side of `bazel run` for a web application: reports the engine's log and exit
// code to the launcher's server. The server inserts this script after the page's engine
// script and wraps the page's `new Engine(GODOT_CONFIG)` in window.__rulesGodot, since
// Engine is a script-scoped binding whose instances cannot be patched from outside.
(function () {
	'use strict';
	const launch = window.__RULES_GODOT__ || {};
	let sequence = 0;

	// One request in flight at a time, carrying every event queued meanwhile: a burst of
	// prints with a request each loses lines.
	const queue = [];
	let sending = false;
	function flush() {
		if (sending || queue.length === 0) {
			return;
		}
		sending = true;
		const batch = queue.splice(0, queue.length);
		fetch('/__rules_godot/events', { method: 'POST', body: JSON.stringify(batch) })
			.catch(function () { /* The launcher is gone. */ })
			.finally(function () {
				sending = false;
				flush();
			});
	}
	function send(kind, data) {
		queue.push(Object.assign({ seq: sequence++, kind: kind }, data));
		flush();
	}

	window.addEventListener('error', function (event) {
		send('page-error', { text: String(event.message || event) });
	});
	// What the page shows in place of the canvas, such as missing browser features.
	document.addEventListener('DOMContentLoaded', function () {
		const notice = document.getElementById('status-notice');
		if (notice) {
			new MutationObserver(function () {
				send('notice', { text: notice.innerText });
			}).observe(notice, { childList: true, subtree: true, characterData: true });
		}
	});

	window.__rulesGodot = function (config) {
		const hooks = {
			onPrint: function () {
				send('stdout', { text: Array.prototype.join.call(arguments, ' ') });
			},
			onPrintError: function () {
				send('stderr', { text: Array.prototype.join.call(arguments, ' ') });
			},
			onExit: function (code) {
				send('exit', { code: code });
			},
		};
		if (Array.isArray(launch.args)) {
			hooks.args = (config.args || []).concat(launch.args);
		}
		return Object.assign({}, config, hooks);
	};
}());
