/// Tiny JSON-Schema builders, so tools read like code instead of maps.
library;

/// `{"type":"object", "properties": …, "required": […]}`
Map<String, Object?> objectSchema({
  required Map<String, Object?> properties,
  List<String> required = const <String>[],
  bool additionalProperties = false,
  String? description,
}) =>
    <String, Object?>{
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      if (description != null) 'description': description,
      'additionalProperties': additionalProperties,
    };

/// `{"type":"string"}`
Map<String, Object?> stringSchema({
  String? description,
  List<String>? enumValues,
  String? pattern,
  int? minLength,
  int? maxLength,
}) =>
    <String, Object?>{
      'type': 'string',
      if (description != null) 'description': description,
      if (enumValues != null) 'enum': enumValues,
      if (pattern != null) 'pattern': pattern,
      if (minLength != null) 'minLength': minLength,
      if (maxLength != null) 'maxLength': maxLength,
    };

/// `{"type":"integer"}`
Map<String, Object?> integerSchema({
  String? description,
  num? minimum,
  num? maximum,
}) =>
    <String, Object?>{
      'type': 'integer',
      if (description != null) 'description': description,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
    };

/// `{"type":"number"}`
Map<String, Object?> numberSchema({
  String? description,
  num? minimum,
  num? maximum,
}) =>
    <String, Object?>{
      'type': 'number',
      if (description != null) 'description': description,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
    };

/// `{"type":"boolean"}`
Map<String, Object?> booleanSchema({String? description}) => <String, Object?>{
      'type': 'boolean',
      if (description != null) 'description': description,
    };

/// `{"type":"array","items": …}`
Map<String, Object?> arraySchema({
  required Map<String, Object?> items,
  String? description,
}) =>
    <String, Object?>{
      'type': 'array',
      'items': items,
      if (description != null) 'description': description,
    };

/// Shorthand for a string enum.
Map<String, Object?> enumSchema(List<String> values, {String? description}) =>
    stringSchema(description: description, enumValues: values);

/// Shorthand for an array of strings.
Map<String, Object?> stringArraySchema({String? description}) =>
    arraySchema(items: stringSchema(), description: description);

/// An empty-argument schema.
Map<String, Object?> emptySchema() => objectSchema(properties: const <String, Object?>{});
