import 'py_tool_definition.dart';

/// Built-in default Python tools seeded on first run (both desktop & server).
///
/// Each tool uses only Python stdlib — no external dependencies required.
/// Tools are inserted into the `py_tools` table when it is empty, so they
/// appear automatically in `list_py_tools` and as dynamic `py_<name>` tools.
List<PyToolDefinition> get defaultPyTools {
  final now = DateTime(
    2025,
    1,
    1,
  ); // fixed anchor — user will see these as "old"
  return [_csvAnalyzer(now), _jsonQuery(now), _textClassify(now)];
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. CSV Analyzer
// ─────────────────────────────────────────────────────────────────────────────

PyToolDefinition _csvAnalyzer(DateTime now) => PyToolDefinition(
  id: '_default_csv_analyzer',
  name: 'csv_analyzer',
  venvReady: false,
  description:
      'Parse and profile CSV data: column-level statistics, null counts, '
      'frequencies, quartiles, and type detection (numeric vs categorical).',
  inputSchema: {
    'type': 'object',
    'properties': {
      'csv_data': {
        'type': 'string',
        'description': 'Raw CSV content (including header row).',
      },
      'delimiter': {
        'type': 'string',
        'description': 'Delimiter character (default: comma).',
        'default': ',',
      },
      'max_rows': {
        'type': 'integer',
        'description': 'Maximum rows to analyze (default: 10000).',
        'default': 10000,
      },
      'top_k': {
        'type': 'integer',
        'description':
            'Show top-K frequent values for categorical columns (default: 5).',
        'default': 5,
      },
    },
    'required': ['csv_data'],
  },
  code: _csvAnalyzerCode,
  requirements: '',
  generationPrompt: '',
  isActive: true,
  createdAt: now,
  updatedAt: now,
);

const _csvAnalyzerCode = '''import csv, io, statistics
from collections import Counter

def execute(args):
    csv_text = args.get("csv_data", "")
    delimiter = args.get("delimiter", ",")
    max_rows = args.get("max_rows", 10000)
    top_k = args.get("top_k", 5)

    if not csv_text.strip():
        return {"error": "csv_data is empty"}

    reader = csv.DictReader(io.StringIO(csv_text), delimiter=delimiter)
    rows = []
    for i, row in enumerate(reader):
        if i >= max_rows:
            break
        rows.append(row)

    if not rows:
        return {"error": "No data rows found", "columns": reader.fieldnames or []}

    columns = reader.fieldnames or list(rows[0].keys())
    profile = {}

    for col in columns:
        values = [r.get(col, "") for r in rows]
        numeric_vals = []
        for v in values:
            try:
                numeric_vals.append(float(v.replace(",", "").strip()))
            except (ValueError, AttributeError):
                pass

        null_count = sum(1 for v in values if not v or v.strip() == "")
        unique_values = len(set(v.strip() for v in values if v.strip()))
        freq = Counter(v.strip() for v in values if v.strip()).most_common(top_k)

        col_profile = {
            "type": "numeric" if len(numeric_vals) > len(values) * 0.5 else "categorical",
            "count": len(values),
            "null_count": null_count,
            "null_pct": round(null_count / len(values) * 100, 2),
            "unique_count": unique_values,
            "top_k_frequencies": [
                {"value": val, "count": cnt} for val, cnt in freq
            ],
        }

        if col_profile["type"] == "numeric":
            sorted_nums = sorted(numeric_vals)
            col_profile.update({
                "min": round(float(min(numeric_vals)), 4),
                "max": round(float(max(numeric_vals)), 4),
                "mean": round(statistics.mean(numeric_vals), 4),
                "median": round(statistics.median(numeric_vals), 4),
                "stdev": round(statistics.stdev(numeric_vals), 4) if len(numeric_vals) > 1 else 0,
                "q1": round(float(sorted_nums[len(sorted_nums)//4]), 4),
                "q3": round(float(sorted_nums[3*len(sorted_nums)//4]), 4),
            })

        profile[col] = col_profile

    return {
        "rows_analyzed": len(rows),
        "columns_found": len(columns),
        "column_names": columns,
        "profile": profile,
    }
''';

// ─────────────────────────────────────────────────────────────────────────────
// 2. JSON Query
// ─────────────────────────────────────────────────────────────────────────────

PyToolDefinition _jsonQuery(DateTime now) => PyToolDefinition(
  id: '_default_json_query',
  name: 'json_query',
  venvReady: false,
  description:
      'Filter, project, sort, group-by, and aggregate JSON datasets using '
      'simple Python expressions. No external dependencies needed.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'data': {
        'type': 'string',
        'description': 'JSON array of objects or a single JSON object.',
      },
      'filter': {
        'type': 'string',
        'description':
            'Python expression to filter rows. Use \'item\' for each element. '
            'E.g., \'item["age"] > 30\'.',
      },
      'project_fields': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Field names to keep in output.',
      },
      'sort_by': {
        'type': 'string',
        'description':
            'Field name to sort by. Prefix with \'-\' for descending.',
      },
      'group_by': {'type': 'string', 'description': 'Field name to group by.'},
      'aggregate': {
        'type': 'object',
        'properties': {
          'field': {'type': 'string'},
          'function': {
            'type': 'string',
            'enum': ['sum', 'avg', 'count', 'min', 'max'],
          },
        },
        'description': 'Aggregation to apply per group.',
      },
      'limit': {'type': 'integer', 'description': 'Max results.'},
    },
    'required': ['data'],
  },
  code: _jsonQueryCode,
  requirements: '',
  generationPrompt: '',
  isActive: true,
  createdAt: now,
  updatedAt: now,
);

const _jsonQueryCode = '''import json
from collections import defaultdict

def execute(args):
    raw = args.get("data", "")
    if isinstance(raw, str):
        data = json.loads(raw)
    else:
        data = raw

    if isinstance(data, dict):
        items = [data]
    elif isinstance(data, list):
        items = data
    else:
        return {"error": "data must be a JSON object or array"}

    original_count = len(items)

    # Filter
    filter_expr = args.get("filter", "").strip()
    if filter_expr:
        filtered = []
        for item in items:
            try:
                if eval(filter_expr, {"__builtins__": {}}, {"item": item}):
                    filtered.append(item)
            except Exception:
                pass
        items = filtered

    # Project fields
    project_fields = args.get("project_fields")
    if project_fields and isinstance(project_fields, list):
        items = [
            {k: item[k] for k in project_fields if k in item}
            for item in items
        ]

    # Sort
    sort_by = args.get("sort_by", "").strip()
    if sort_by:
        desc = sort_by.startswith("-")
        field = sort_by.lstrip("-")
        items.sort(key=lambda x: x.get(field, ""), reverse=desc)

    # Group + Aggregate
    group_by = args.get("group_by", "").strip()
    aggregate = args.get("aggregate")
    result = items

    if group_by and aggregate:
        groups = defaultdict(list)
        for item in items:
            key = str(item.get(group_by, "null"))
            groups[key].append(item)

        agg_field = aggregate.get("field", "")
        agg_func = aggregate.get("function", "count").lower()
        grouped_result = {}
        for key, group in groups.items():
            vals = [g.get(agg_field, 0) for g in group if agg_field in g]
            numeric = [v for v in vals if isinstance(v, (int, float))]
            if agg_func == "count":
                grouped_result[key] = len(group)
            elif agg_func == "sum":
                grouped_result[key] = sum(numeric)
            elif agg_func == "avg":
                grouped_result[key] = round(sum(numeric) / len(numeric), 4) if numeric else None
            elif agg_func == "min":
                grouped_result[key] = min(numeric) if numeric else None
            elif agg_func == "max":
                grouped_result[key] = max(numeric) if numeric else None
        result = grouped_result
    elif group_by:
        groups = defaultdict(list)
        for item in items:
            key = str(item.get(group_by, "null"))
            groups[key].append(item)
        result = dict(groups)

    # Limit
    limit = args.get("limit")
    if limit and isinstance(result, list):
        result = result[:int(limit)]

    return {
        "original_count": original_count,
        "filtered_count": len(items) if isinstance(items, list) else None,
        "result": result,
    }
''';

// ─────────────────────────────────────────────────────────────────────────────
// 3. Text Classify
// ─────────────────────────────────────────────────────────────────────────────

PyToolDefinition _textClassify(DateTime now) => PyToolDefinition(
  id: '_default_text_classify',
  name: 'text_classify',
  venvReady: false,
  description:
      'Classify text snippets against user-defined keyword rules. '
      'Each rule specifies a label, include/exclude keywords, and a minimum '
      'match threshold. Returns best-matching labels with confidence scores.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'description': 'The input text to classify.'},
      'rules': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'label': {'type': 'string'},
            'include_keywords': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'exclude_keywords': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'min_score': {
              'type': 'number',
              'description': 'Minimum match fraction (0.0-1.0, default: 0.5).',
            },
          },
          'required': ['label', 'include_keywords'],
        },
      },
      'case_sensitive': {
        'type': 'boolean',
        'description': 'Case-sensitive matching (default: false).',
        'default': false,
      },
      'top_k': {
        'type': 'integer',
        'description': 'Return top-K matching labels (default: 3).',
        'default': 3,
      },
    },
    'required': ['text', 'rules'],
  },
  code: _textClassifyCode,
  requirements: '',
  generationPrompt: '',
  isActive: true,
  createdAt: now,
  updatedAt: now,
);

const _textClassifyCode = '''import re

def execute(args):
    text = args.get("text", "")
    rules = args.get("rules", [])
    case_sensitive = args.get("case_sensitive", False)
    top_k = args.get("top_k", 3)

    if not text.strip():
        return {"error": "text is empty"}
    if not rules:
        return {"error": "no rules provided", "classifications": []}

    if not case_sensitive:
        text_lower = text.lower()
    else:
        text_lower = text

    def _matches(text, keywords, case_sensitive):
        matched = 0
        total = 0
        for kw in keywords:
            if not kw.strip():
                continue
            total += 1
            target = kw if case_sensitive else kw.lower()
            pattern = re.compile(r'\\b' + re.escape(target) + r'\\b',
                                 re.IGNORECASE if not case_sensitive else 0)
            if pattern.search(text):
                matched += 1
        return matched, total

    scores = []
    for rule in rules:
        label = rule.get("label", "unknown")
        include_kw = rule.get("include_keywords", [])
        exclude_kw = rule.get("exclude_keywords", [])
        min_score = float(rule.get("min_score", 0.5))

        if not include_kw:
            continue

        # Check exclusions first
        if exclude_kw:
            excl_matched, _ = _matches(text_lower, exclude_kw, case_sensitive)
            if excl_matched > 0:
                continue

        inc_matched, inc_total = _matches(text_lower, include_kw, case_sensitive)
        if inc_total == 0:
            continue

        score = round(inc_matched / inc_total, 4)
        if score >= min_score:
            scores.append({
                "label": label,
                "score": score,
                "matched_keywords": inc_matched,
                "total_keywords": inc_total,
            })

    scores.sort(key=lambda s: s["score"], reverse=True)
    best = scores[:top_k]

    # Extract matched keyword highlights from best result
    highlights = []
    if best:
        for rule in rules:
            if rule.get("label") == best[0]["label"]:
                for kw in rule.get("include_keywords", []):
                    target = kw if case_sensitive else kw.lower()
                    pattern = re.compile(re.escape(target),
                                         re.IGNORECASE if not case_sensitive else 0)
                    if pattern.search(text if case_sensitive else text_lower):
                        highlights.append(kw)
                break

    return {
        "text_length": len(text),
        "rules_evaluated": len(rules),
        "classifications": best,
        "best_label": best[0]["label"] if best else None,
        "best_score": best[0]["score"] if best else 0.0,
        "matched_highlights": highlights[:10],
    }
''';
