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
