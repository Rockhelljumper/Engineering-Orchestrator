import { test } from 'node:test';
import assert from 'node:assert/strict';
import { validate, type Schema } from '../../src/schema.ts';

const s: Schema = {
  type: 'object',
  required: ['a', 'b'],
  additionalProperties: false,
  properties: {
    a: { type: 'integer', minimum: 1 },
    b: { type: 'array', minItems: 1, items: { type: 'string', pattern: '^x' } },
    c: { type: ['number', 'null'] },
    d: { enum: ['p', 'q'] },
    e: { type: 'number', exclusiveMinimum: 0 },
  },
};

test('accepts a valid value', () => {
  assert.deepEqual(validate(s, { a: 1, b: ['xy'], c: null, d: 'p', e: 0.5 }), []);
});

test('reports each kind of violation', () => {
  const cases: Array<[unknown, RegExp]> = [
    [{ b: ['x'] }, /missing required property "a"/],
    [{ a: 0, b: ['x'] }, /must be >= 1/],
    [{ a: 1.5, b: ['x'] }, /must be integer/],
    [{ a: 1, b: [] }, /must have >= 1 items/],
    [{ a: 1, b: ['y'] }, /must match/],
    [{ a: 1, b: ['x'], z: 1 }, /unexpected property "z"/],
    [{ a: 1, b: ['x'], c: 'no' }, /must be number\|null/],
    [{ a: 1, b: ['x'], d: 'r' }, /must be one of/],
    [{ a: 1, b: ['x'], e: 0 }, /must be > 0/],
    ['str', /must be object/],
  ];
  for (const [value, re] of cases) {
    const errs = validate(s, value).map((e) => e.message).join('; ');
    assert.match(errs, re, JSON.stringify(value));
  }
});

test('rejects non-finite numbers', () => {
  assert.notDeepEqual(validate({ type: 'number' }, Number.POSITIVE_INFINITY), []);
});

test('only own properties count: "__proto__" or "constructor" never match something inherited', () => {
  const strict = { type: 'object', required: ['a'], additionalProperties: false, properties: { a: { type: 'number' } } };
  assert.match(validate(strict, JSON.parse('{"a":1,"__proto__":{"x":1}}')).map((e) => e.message).join('; '), /unexpected property "__proto__"/);
  assert.match(validate(strict, { a: 1, constructor: 'x' }).map((e) => e.message).join('; '), /unexpected property "constructor"/);
  assert.match(validate({ type: 'object', required: ['toString'] }, {}).map((e) => e.message).join('; '), /missing required property "toString"/);
});

test('maxLength and maxItems: at the limit passes, one over fails', () => {
  const lim: Schema = { type: 'object', properties: { s: { type: 'string', maxLength: 3 }, a: { type: 'array', maxItems: 2, items: { type: 'string', maxLength: 1 } } } };
  assert.deepEqual(validate(lim, { s: 'abc', a: ['x', 'y'] }), []);
  assert.match(validate(lim, { s: 'abcd' }).map((e) => e.message).join('; '), /must have length <= 3/);
  assert.match(validate(lim, { a: ['x', 'y', 'z'] }).map((e) => e.message).join('; '), /must have <= 2 items/);
  assert.match(validate(lim, { a: ['xy'] }).map((e) => `${e.path} ${e.message}`).join('; '), /\$\.a\[0\] must have length <= 1/);
  // An array over maxItems is reported once, not item by item.
  assert.deepEqual(validate(lim, { a: Array.from({ length: 1000 }, () => 'too long') }).map((e) => e.path), ['$.a']);
});
