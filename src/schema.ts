/**
 * Minimal JSON Schema validator for the subset eo uses (type, required, properties,
 * additionalProperties, items, enum, const, minimum, maximum, minLength, minItems, pattern,
 * nullable via type arrays). `ajv` was the planned dependency; M1 avoids any new install, so
 * this subset is implemented and unit-tested here instead.
 */
export interface Schema {
  type?: string | string[];
  required?: string[];
  properties?: Record<string, Schema>;
  additionalProperties?: boolean | Schema;
  items?: Schema;
  enum?: unknown[];
  const?: unknown;
  minimum?: number;
  maximum?: number;
  exclusiveMinimum?: number;
  minLength?: number;
  minItems?: number;
  pattern?: string;
  description?: string;
}

export interface ValidationError {
  path: string;
  message: string;
}

export function validate(schema: Schema, value: unknown, path = '$'): ValidationError[] {
  const errors: ValidationError[] = [];
  check(schema, value, path, errors);
  return errors;
}

export function assertValid(schema: Schema, value: unknown, what: string): void {
  const errors = validate(schema, value);
  if (errors.length > 0) {
    throw new Error(`${what} is invalid: ` + errors.map((e) => `${e.path} ${e.message}`).join('; '));
  }
}

function typeOf(value: unknown): string {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number';
  return typeof value;
}

function typeMatches(expected: string, actual: string): boolean {
  return expected === actual || (expected === 'number' && actual === 'integer');
}

function check(schema: Schema, value: unknown, path: string, errors: ValidationError[]): void {
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    const actual = typeOf(value);
    if (!types.some((t) => typeMatches(t, actual))) {
      errors.push({ path, message: `must be ${types.join('|')}, got ${actual}` });
      return;
    }
  }
  if (schema.const !== undefined && value !== schema.const) {
    errors.push({ path, message: `must equal ${JSON.stringify(schema.const)}` });
  }
  if (schema.enum !== undefined && !schema.enum.includes(value)) {
    errors.push({ path, message: `must be one of ${JSON.stringify(schema.enum)}` });
  }
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) errors.push({ path, message: `must be >= ${schema.minimum}` });
    if (schema.maximum !== undefined && value > schema.maximum) errors.push({ path, message: `must be <= ${schema.maximum}` });
    if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) {
      errors.push({ path, message: `must be > ${schema.exclusiveMinimum}` });
    }
    if (!Number.isFinite(value)) errors.push({ path, message: 'must be finite' });
  }
  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push({ path, message: `must have length >= ${schema.minLength}` });
    }
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(value)) {
      errors.push({ path, message: `must match ${schema.pattern}` });
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push({ path, message: `must have >= ${schema.minItems} items` });
    }
    if (schema.items !== undefined) value.forEach((item, i) => check(schema.items as Schema, item, `${path}[${i}]`, errors));
  }
  if (typeOf(value) === 'object') {
    const obj = value as Record<string, unknown>;
    for (const key of schema.required ?? []) {
      if (!(key in obj)) errors.push({ path, message: `missing required property "${key}"` });
    }
    const props = schema.properties ?? {};
    for (const [key, v] of Object.entries(obj)) {
      const sub = props[key];
      if (sub !== undefined) {
        check(sub, v, `${path}.${key}`, errors);
      } else if (schema.additionalProperties === false) {
        errors.push({ path, message: `unexpected property "${key}"` });
      } else if (typeof schema.additionalProperties === 'object') {
        check(schema.additionalProperties, v, `${path}.${key}`, errors);
      }
    }
  }
}
