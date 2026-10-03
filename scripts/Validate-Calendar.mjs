import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

function validate(filename) {
const kind = path.basename(filename);
const isDates = kind === 'persian-dates.ics';
const isHolidays = kind === 'iran-holidays.ics';
assert(isDates || isHolidays || kind === 'iran-culture.ics', 'Unknown feed filename');
const bytes = fs.readFileSync(filename);
const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
assert(!bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191])), 'Unexpected UTF-8 BOM');
assert(text.endsWith('\r\n'), 'Missing final CRLF');
assert(!/(?<!\r)\n|\r(?!\n)/.test(text), 'Line endings must be CRLF');
for (const line of text.split('\r\n')) {
  assert(Buffer.byteLength(line, 'utf8') <= 75, 'Unfolded physical line exceeds 75 octets');
}
const lines = text.replace(/\r\n[ \t]/g, '').trimEnd().split('\r\n');
const allowed = new Set(['BEGIN', 'END', 'VERSION', 'PRODID', 'CALSCALE', 'METHOD', 'X-WR-CALNAME', 'X-WR-CALDESC', 'UID', 'DTSTAMP', 'DTSTART', 'DTEND', 'SUMMARY', 'DESCRIPTION', 'TRANSP']);
const components = [];
const events = [];
let event;
for (const line of lines) {
  const match = /^([A-Z-]+)(;[^:]*)?:(.*)$/.exec(line);
  assert(match, 'Invalid iCalendar content line');
  const [, property, parameters = '', value] = match;
  assert(allowed.has(property), `Unexpected property: ${property}`);
  if (property === 'BEGIN') {
    assert(['VCALENDAR', 'VEVENT'].includes(value), 'Unexpected component');
    assert.equal(components.length, value === 'VCALENDAR' ? 0 : 1, 'Invalid component nesting');
    components.push(value);
    if (value === 'VEVENT') event = {};
  } else if (property === 'END') {
    assert.equal(components.pop(), value, 'Unbalanced component');
    if (value === 'VEVENT') { events.push(event); event = undefined; }
  } else if (event) {
    assert(!(property in event), `Duplicate property: ${property}`);
    event[property] = { parameters, value };
  }
}
assert.equal(components.length, 0);
assert(events.length > 0);
assert(!/(?:https?:\/\/|webcal:|mailto:|javascript:|data:|file:|<script|<iframe|<img)/i.test(text), 'External links or active markup found');
const digitsToLatin = value => value.replace(/[۰-۹]/g, digit => String(digit.charCodeAt(0) - 1776));
const parseDate = value => {
  assert(/^\d{8}$/.test(value), 'Expected all-day date');
  const date = new Date(`${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}T00:00:00Z`);
  assert.equal(date.toISOString().slice(0, 10).replaceAll('-', ''), value, 'Invalid Gregorian date');
  return date;
};
const persian = new Intl.DateTimeFormat('en-US-u-ca-persian-nu-latn', { timeZone: 'UTC', year: 'numeric', month: '2-digit', day: '2-digit' });
assert.equal(persian.resolvedOptions().calendar, 'persian');
const weekdays = ['یکشنبه', 'دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنجشنبه', 'جمعه', 'شنبه'];
const months = ['فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'];
const uids = new Set();
let previous;
for (const e of events) {
  assert.deepEqual(Object.keys(e).sort(), ['UID', 'DTSTAMP', 'DTSTART', 'DTEND', 'SUMMARY', 'DESCRIPTION', 'TRANSP'].sort());
  assert.equal(e.DTSTART.parameters, ';VALUE=DATE');
  assert.equal(e.DTEND.parameters, ';VALUE=DATE');
  const date = parseDate(e.DTSTART.value);
  assert.equal(+parseDate(e.DTEND.value) - +date, 86400000, 'DTEND must be the next day');
  if (previous && isDates) assert.equal(+date - +previous, 86400000, 'Missing or duplicate day');
  if (previous && !isDates) assert(+date > +previous, 'Duplicate or out-of-order occasion date');
  previous = date;
  assert(!uids.has(e.UID.value), 'Duplicate UID');
  uids.add(e.UID.value);
  assert.equal(e.TRANSP.value, 'TRANSPARENT', 'Date must not mark the user busy');
  const parts = Object.fromEntries(persian.formatToParts(date).map(part => [part.type, part.value]));
  const expected = `${parts.year}/${parts.month}/${parts.day}`;
  const description = digitsToLatin(e.DESCRIPTION.value);
  const expectedDescription = `شمسی: ${expected}\\nمیلادی: ${date.toISOString().slice(0, 10)}`;
  assert(isDates ? description === expectedDescription : description.startsWith(expectedDescription + '\\n'), 'Persian date disagrees with independent ICU conversion');
  const title = digitsToLatin(e.SUMMARY.value);
  const compact = `${weekdays[date.getUTCDay()]}، ${Number(parts.day)} ${months[Number(parts.month) - 1]}`;
  if (isDates) assert([compact, `${compact} ${parts.year}`].includes(title), 'Incorrect title or weekday');
  else {
    const dataset = JSON.parse(fs.readFileSync(new URL(isHolidays ? '../data/holidays-1405.json' : '../data/cultural.json', import.meta.url), 'utf8'));
    const sourceEvent = dataset.events.find(item => item.month === Number(parts.month) && item.day === Number(parts.day));
    assert(sourceEvent, 'Occasion has no reviewed source entry');
    if (isHolidays) assert.equal(Number(parts.year), dataset.year, 'Unverified holiday year');
    assert.equal(e.SUMMARY.value, (isHolidays ? 'تعطیل: ' : '') + sourceEvent.title, 'Occasion title disagrees with reviewed data');
  }
}
if (isHolidays) {
  assert.equal(events.length, 26, 'Expected all 26 distinct scheduled holiday dates');
  for (const [day, phrase] of [['20260321','عید فطر'], ['20260414','جعفر صادق'], ['20260604','غدیر'], ['20261113','فاطمه'], ['20270310','عید فطر']]) {
    assert(events.some(e => e.DTSTART.value === day && e.SUMMARY.value.includes(phrase)), 'Published calendar anchor mismatch');
  }
}
if (!isDates && !isHolidays) {
  const dataset = JSON.parse(fs.readFileSync(new URL('../data/cultural.json', import.meta.url), 'utf8'));
  const counts = new Map();
  for (const e of events) {
    const year = digitsToLatin(e.DESCRIPTION.value).match(/^شمسی: (\d{4})\//)[1];
    counts.set(year, (counts.get(year) ?? 0) + 1);
  }
  for (const count of counts.values()) assert.equal(count, dataset.events.length, 'Missing cultural occasion');
}
return { status: 'passed', feed: kind, events: events.length, first: events[0].DTSTART.value, last: events.at(-1).DTSTART.value };
}
const targets = process.argv.slice(2);
const filenames = targets.length ? targets : ['persian-dates.ics', 'iran-holidays.ics', 'iran-culture.ics'].map(name => fileURLToPath(new URL(`../feeds/${name}`, import.meta.url)));
console.log(JSON.stringify(filenames.map(validate), null, 2));
