import React from "react";
import { z } from "zod";
import {
  createLibrary,
  defineComponent,
  reactive,
  useStateField,
  useTriggerAction,
  action,
} from "@openuidev/react-lang";
const Text = defineComponent({
  name: "Text",
  description: "Plain text or a computed value.",
  props: z.object({ text: z.union([z.string(), z.number()]) }),
  component: ({ props }) => <p>{props.text}</p>,
});
const Heading = defineComponent({
  name: "Heading",
  description: "Section heading.",
  props: z.object({ text: z.string() }),
  component: ({ props }) => <h3>{props.text}</h3>,
});
const Metric = defineComponent({
  name: "Metric",
  description: "A labeled numeric result.",
  props: z.object({
    label: z.string(),
    value: z.union([z.string(), z.number()]),
    unit: z.string().optional(),
  }),
  component: ({ props }) => (
    <div className="metric">
      <span>{props.label}</span>
      <strong>
        {props.value}
        <small>{props.unit}</small>
      </strong>
    </div>
  ),
});
const Badge = defineComponent({
  name: "Badge",
  description: "Short neutral label.",
  props: z.object({ text: z.string() }),
  component: ({ props }) => <span className="badge">{props.text}</span>,
});
const Input = defineComponent({
  name: "Input",
  description: "Editable text; bind value to a $variable.",
  props: z.object({ value: reactive(z.string()), label: z.string() }),
  component: ({ props }) => {
    const f = useStateField("value", props.value);
    return (
      <label className="field">
        {props.label}
        <input
          value={f.value ?? ""}
          onChange={(e) => f.setValue(e.target.value)}
        />
      </label>
    );
  },
});
const NumberInput = defineComponent({
  name: "NumberInput",
  description: "Editable number; bind value to a $variable.",
  props: z.object({
    value: reactive(z.number()),
    label: z.string(),
    min: z.number().optional(),
    max: z.number().optional(),
  }),
  component: ({ props }) => {
    const f = useStateField("value", props.value);
    return (
      <label className="field">
        {props.label}
        <input
          type="number"
          min={props.min}
          max={props.max}
          value={f.value ?? 0}
          onChange={(e) => {
            if (Number.isFinite(e.target.valueAsNumber))
              f.setValue(e.target.valueAsNumber);
          }}
        />
      </label>
    );
  },
});
const Slider = defineComponent({
  name: "Slider",
  description: "Interactive numeric range; bind value to a $variable.",
  props: z.object({
    value: reactive(z.number()),
    label: z.string(),
    min: z.number(),
    max: z.number(),
    step: z.number().optional(),
  }),
  component: ({ props }) => {
    const f = useStateField("value", props.value);
    return (
      <label className="field">
        {props.label}
        <output>{f.value}</output>
        <input
          type="range"
          min={props.min}
          max={props.max}
          step={props.step ?? 1}
          value={f.value ?? props.min}
          onChange={(e) => f.setValue(Number(e.target.value))}
        />
      </label>
    );
  },
});
const Checkbox = defineComponent({
  name: "Checkbox",
  description: "Boolean choice; bind value to a $variable.",
  props: z.object({ value: reactive(z.boolean()), label: z.string() }),
  component: ({ props }) => {
    const f = useStateField("value", props.value);
    return (
      <label className="choice">
        <input
          type="checkbox"
          checked={f.value ?? false}
          onChange={(e) => f.setValue(e.target.checked)}
        />
        {props.label}
      </label>
    );
  },
});
const Select = defineComponent({
  name: "Select",
  description: "Choice of text options; bind value to a $variable.",
  props: z.object({
    value: reactive(z.string()),
    label: z.string(),
    options: z.array(z.string()),
  }),
  component: ({ props }) => {
    const f = useStateField("value", props.value);
    return (
      <label className="field">
        {props.label}
        <select
          value={f.value ?? ""}
          onChange={(e) => f.setValue(e.target.value)}
        >
          {props.options.map((s: string) => (
            <option key={s}>{s}</option>
          ))}
        </select>
      </label>
    );
  },
});
const Button = defineComponent({
  name: "Button",
  description:
    "User-clicked action. @ToAssistant sends a follow-up; @Set changes local UI state.",
  props: z.object({ label: z.string(), onClick: action().optional() }),
  component: ({ props }) => {
    const trigger = useTriggerAction();
    return (
      <button onClick={() => trigger(props.label, undefined, props.onClick)}>
        {props.label}
      </button>
    );
  },
});
const Table = defineComponent({
  name: "Table",
  description: "Data table with column labels and rows.",
  props: z.object({
    columns: z.array(z.string()),
    rows: z.array(z.array(z.union([z.string(), z.number()]))),
  }),
  component: ({ props }) => (
    <div className="table-scroll">
      <table>
        <thead>
          <tr>
            {props.columns.map((s: string, i: number) => (
              <th key={i}>{s}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {props.rows.map((r: (string | number)[], i: number) => (
            <tr key={i}>
              {r.map((s, j) => (
                <td key={j}>{s}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  ),
});
const BarChart = defineComponent({
  name: "BarChart",
  description: "Labeled horizontal bars for non-negative values.",
  props: z.object({
    labels: z.array(z.string()),
    values: z.array(z.number()),
    unit: z.string().optional(),
  }),
  component: ({ props }) => {
    const max = Math.max(1, ...props.values);
    return (
      <div
        className="bar-chart"
        role="img"
        aria-label={props.labels
          .map(
            (s: string, i: number) =>
              `${s}: ${props.values[i]} ${props.unit ?? ""}`,
          )
          .join(", ")}
      >
        {props.labels.map((s: string, i: number) => (
          <div className="bar-line" key={i}>
            <span>{s}</span>
            <meter
              min={0}
              max={max}
              value={Math.max(0, props.values[i] ?? 0)}
            />
            <span>
              {props.values[i]} {props.unit}
            </span>
          </div>
        ))}
      </div>
    );
  },
});
const LineChart = defineComponent({
  name: "LineChart",
  description: "A line chart with accessible values.",
  props: z.object({ labels: z.array(z.string()), values: z.array(z.number()) }),
  component: ({ props }) => {
    const min = Math.min(0, ...props.values),
      max = Math.max(1, ...props.values),
      span = max - min;
    return (
      <figure>
        <svg
          viewBox="0 0 600 180"
          role="img"
          aria-label={props.labels
            .map((s: string, i: number) => `${s}: ${props.values[i]}`)
            .join(", ")}
        >
          <polyline
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            points={props.values
              .map(
                (v: number, i: number) =>
                  `${10 + (i * 580) / Math.max(1, props.values.length - 1)},${170 - ((v - min) * 160) / span}`,
              )
              .join(" ")}
          />
        </svg>
        <figcaption>{props.labels.join(" · ")}</figcaption>
      </figure>
    );
  },
});
const children = z.array(z.any());
const Stack = defineComponent({
  name: "Stack",
  description: "Vertical layout of components.",
  props: z.object({ children }),
  component: ({ props, renderNode }) => (
    <div className="ui-stack">
      {props.children.map((c: unknown, i: number) => (
        <React.Fragment key={i}>{renderNode(c)}</React.Fragment>
      ))}
    </div>
  ),
});
const Row = defineComponent({
  name: "Row",
  description: "Responsive horizontal layout; wraps when narrow.",
  props: z.object({ children }),
  component: ({ props, renderNode }) => (
    <div className="ui-row">
      {props.children.map((c: unknown, i: number) => (
        <div key={i}>{renderNode(c)}</div>
      ))}
    </div>
  ),
});
const Card = defineComponent({
  name: "Card",
  description: "A titled group of related components.",
  props: z.object({ title: z.string(), children }),
  component: ({ props, renderNode }) => (
    <section className="ui-card">
      <h3>{props.title}</h3>
      {props.children.map((c: unknown, i: number) => (
        <React.Fragment key={i}>{renderNode(c)}</React.Fragment>
      ))}
    </section>
  ),
});
export const library = createLibrary({
  root: "Stack",
  components: [
    Stack,
    Row,
    Card,
    Heading,
    Text,
    Metric,
    Badge,
    Input,
    NumberInput,
    Slider,
    Checkbox,
    Select,
    Button,
    Table,
    BarChart,
    LineChart,
  ],
});
export const calculator =
  'root = Stack([Heading("작업 시간 계산"), Slider($hours, "하루 작업 시간", 1, 12, 1), Metric("주간 작업 시간", $hours * 5, "시간")])\n$hours = 4';
export const prompt = library.prompt({
  preamble:
    "You are Stallari, Knarr's assistant. Reply in Korean Markdown. When useful, include interactive UI only inside fenced openui blocks, using the component and language specification below.",
  inlineMode: true,
  bindings: true,
  builtinFunctions: true,
  toolCalls: false,
  additionalRules: [
    "Reply in Korean. Use ordinary Markdown for prose. Use fenced ```openui blocks only when an interactive tool or visual comparison helps the user.",
    "Use only this library. Never emit HTML, JavaScript, external resources, Query or Mutation. No external network tools are connected.",
    "Local controls must bind to $variables and update a visible result. Use @ToAssistant only for an intentional user follow-up. Never represent approval or worker execution as a generic UI button; Knarr owns those versioned cards.",
    "Put root first. Close each openui code fence. Use real data from tools for project information. Distinguish user assumptions from measured data.",
    "Show a picture you captured or read from this Mac as `![설명](/절대/경로)` Markdown on its own line. Knarr renders that line as the image and opens it in Quick Look when clicked. External image URLs are never loaded; PNG, JPEG, GIF, WebP and HEIC under 10MB work.",
  ],
  examples: [calculator],
});
