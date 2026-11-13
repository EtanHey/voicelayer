// Typed-delivery fixture editors (lane T7). Bundled by build-fixture.ts from a READ-ONLY
// T3 Code checkout's own sources and node_modules: `t3web/*` resolves to <T3CODE_DIR>/apps/web/src/*.
// Nothing here is Etan's text; the page only receives synthetic key events from drive.ts.
import { Editor, InputRule } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { splitBlockKeepMarks } from "@tiptap/pm/commands";
import {
  ComposerListExtensions,
  ComposerTaskListExtension,
  ComposerTaskItemExtension,
  splitOrLiftListItem,
  serializeEditorDoc,
  buildDocJson,
} from "t3web/composer-rich-text-doc";
import { ComposerMarkdownSourceExtension, collapseShownMarkdownSource } from "t3web/composer-markdown-source";
import { listContinuationForEnter } from "t3web/composer-list-continuation";

// Copied from T3 Code apps/web/src/components/ComposerPromptEditorTiptap.tsx (listMarkerInputRule,
// not exported). Same body; only the type annotations are dropped.
function listMarkerInputRule(find: RegExp, listType: "bulletList" | "orderedList") {
  return new InputRule({
    find,
    handler: ({ state, range, match, chain }: any) => {
      const marker = match.groups?.marker ?? "-";
      const space = match.groups?.space ?? " ";
      const carried = match.groups?.carried ?? "";
      const $from = state.doc.resolve(range.from);
      if ($from.parent.type.name !== "paragraph" || $from.depth !== 1) return null;
      const command = chain()
        .deleteRange(range)
        .wrapInList(listType, listType === "orderedList" ? { start: Number.parseInt(marker, 10) || 1 } : {})
        .updateAttributes("listItem", { marker, space });
      (carried ? command.insertContent(carried) : command).run();
      return undefined;
    },
  });
}

// The list/markdown subset of T3's createComposerExtensions(true): the same StarterKit switches, the
// same list extensions and input rules. Chips, code blocks, quotes and headings are left out: dictated
// list text never reaches them.
const t3RichExtensions = [
  StarterKit.configure({
    blockquote: false, bulletList: false, codeBlock: false, heading: false, horizontalRule: false,
    listItem: false, link: false, orderedList: false, underline: false, dropcursor: false,
    gapcursor: false, trailingNode: false, code: false, listKeymap: false, italic: false, bold: false, strike: false,
  }),
  ComposerMarkdownSourceExtension,
  ...ComposerListExtensions.map((extension: any) =>
    extension.name === "listItem"
      ? extension
      : extension.extend({
          addInputRules() {
            return this.name === "bulletList"
              ? [
                  listMarkerInputRule(/^(?<marker>[*+])(?<space>\s)$/, "bulletList"),
                  listMarkerInputRule(/^(?<marker>-)(?<space>[ \t]+)(?<carried>[^\s[])$/, "bulletList"),
                ]
              : [listMarkerInputRule(/^(?<marker>\d+[.)])(?<space>\s)$/, "orderedList")];
          },
        }),
  ),
  ComposerTaskListExtension,
  ComposerTaskItemExtension,
];

// T3's Enter path for a Shift+Enter (not a submit): ChatComposer's composerCommandKey handler runs first
// (`if (key === "Enter" && isTaskItem) return false;` with isTaskItem = task||list item, else
// applyListEdit(listContinuationForEnter) on the Markdown prompt), then the editor splits the list item
// (splitOrLiftListItem) or the block (splitBlockKeepMarks). Mirrors ComposerPromptEditorTiptap.tsx
// handleKeyDown and components/chat/composerCommandKey.ts.
function t3Enter(editor: Editor, event: KeyboardEvent): boolean {
  if (event.key !== "Enter" || event.metaKey || event.ctrlKey || event.isComposing) return false;
  const isTaskItem = editor.isActive("taskItem");
  const isListItem = editor.isActive("listItem");
  if (!(isTaskItem || isListItem)) {
    const value = serializeEditorDoc(editor.state.doc).value;
    const atEnd = editor.state.selection.empty && editor.state.selection.to === editor.state.doc.content.size - 1;
    const edit = atEnd ? listContinuationForEnter(value, value.length) : null;
    if (edit) {
      // applyPromptReplacement: the composer re-renders the editor from the new Markdown prompt.
      const next = value.slice(0, edit.start) + edit.replacement + value.slice(edit.end);
      editor.commands.setContent(buildDocJson(next, () => null, { styling: true }) as any);
      editor.commands.focus("end");
      event.preventDefault();
      return true;
    }
  }
  event.preventDefault();
  if ((isTaskItem || isListItem) && splitOrLiftListItem(editor, collapseShownMarkdownSource)) return true;
  return editor.chain().command(collapseShownMarkdownSource)
    .command(({ state, dispatch }: any) => splitBlockKeepMarks(state, dispatch)).run();
}

function mountT3Rich(el: HTMLElement) {
  const editor: Editor = new Editor({
    element: el,
    extensions: t3RichExtensions as any,
    editorProps: {
      attributes: { class: "composer-tiptap" }, handleKeyDown: (_view, event) => t3Enter(editor, event) },
  });
  return { read: () => serializeEditorDoc(editor.state.doc).value, clear: () => editor.commands.clearContent(),
    focus: () => editor.commands.focus("end") };
}

// Stock Tiptap 3 StarterKit: ProseMirror's default list behaviour (typed "1. "/"- " input rules, Enter
// splits a list item, Shift+Enter is a hard break). Read back as Markdown-style text.
function mountTiptapStock(el: HTMLElement) {
  const editor = new Editor({ element: el, extensions: [StarterKit] });
  const read = () => {
    const lines: string[] = [];
    const inline = (node: any) => {
      let s = "";
      node.forEach((child: any) => { s += child.type.name === "hardBreak" ? "\n" : (child.text ?? ""); });
      return s;
    };
    editor.state.doc.forEach((block: any) => {
      if (block.type.name === "orderedList" || block.type.name === "bulletList") {
        let n = block.attrs.start ?? 1;
        block.forEach((item: any) => {
          const marker = block.type.name === "orderedList" ? `${n++}. ` : "- ";
          const text: string[] = [];
          item.forEach((p: any) => text.push(inline(p)));
          lines.push(marker + text.join("\n"));
        });
      } else lines.push(inline(block));
    });
    return lines.join("\n");
  };
  return { read, clear: () => editor.commands.clearContent(), focus: () => editor.commands.focus("end") };
}

// T3 Code's plain-text composer mode: Shift+Enter runs the same applyListEdit(listContinuationForEnter)
// over the prompt string. Modelled as a textarea whose value is that prompt.
function mountT3Plain(el: HTMLTextAreaElement) {
  el.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || event.metaKey || event.ctrlKey || event.isComposing) return;
    if (el.selectionStart !== el.selectionEnd) return;
    const edit = listContinuationForEnter(el.value, el.selectionStart);
    if (!edit) return;
    event.preventDefault();
    el.setRangeText(edit.replacement, edit.start, edit.end, "end");
    el.selectionStart = el.selectionEnd = edit.cursorAfter;
  });
  return { read: () => el.value, clear: () => { el.value = ""; }, focus: () => el.focus() };
}

function mountTextarea(el: HTMLTextAreaElement) {
  return { read: () => el.value, clear: () => { el.value = ""; }, focus: () => el.focus() };
}

function mountContentEditable(el: HTMLElement) {
  return { read: () => el.innerText.replace(/\n$/, ""), clear: () => { el.innerHTML = ""; },
    focus: () => { el.focus(); const r = document.createRange(); r.selectNodeContents(el); r.collapse(false);
      const s = getSelection()!; s.removeAllRanges(); s.addRange(r); } };
}

const q = (id: string) => document.getElementById(id)!;
(window as any).fixtureEditors = {
  "t3-rich": mountT3Rich(q("t3-rich")),
  "t3-plain": mountT3Plain(q("t3-plain") as HTMLTextAreaElement),
  "tiptap-stock": mountTiptapStock(q("tiptap-stock")),
  contenteditable: mountContentEditable(q("contenteditable")),
  textarea: mountTextarea(q("textarea") as HTMLTextAreaElement),
};
(window as any).fixtureReady = true;
