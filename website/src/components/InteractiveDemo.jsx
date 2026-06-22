import {
  Check,
  Copy,
  EyeOff,
  Languages,
  ListMinus,
  MessageSquareCheck,
  Pencil,
  Settings,
  SquarePen,
  Volume2,
  WandSparkles,
  X
} from "lucide-react";
import { useState } from "react";

const initialText =
  "The cable car station starts around 830 meters above sea level.";

const actionResults = {
  Prompt: "Explain that the cable car station starts at about 830 metres.",
  Improve: "The cable car station is located about 830 metres above sea level.",
  Shorten: "Cable car station: about 830 metres above sea level.",
  Proofread:
    "The cable car station starts around 830 metres above sea level.",
  Translate:
    "Le départ des télécabines se situe à environ 830 mètres d’altitude.",
  Speak: "Playing the selected text."
};

const actions = [
  { label: "Prompt", icon: SquarePen },
  { label: "Improve", icon: WandSparkles },
  { label: "Shorten", icon: ListMinus },
  { label: "Proofread", icon: MessageSquareCheck },
  { label: "Translate", icon: Languages, suffix: "en" },
  { label: "Speak", icon: Volume2, suffix: "US" }
];

export function InteractiveDemo() {
  const [text, setText] = useState(initialText);
  const [isSelected, setIsSelected] = useState(false);
  const [activeAction, setActiveAction] = useState(null);
  const [copied, setCopied] = useState(false);
  const [isEditing, setIsEditing] = useState(false);
  const [editedResult, setEditedResult] = useState("");

  const result = activeAction
    ? editedResult || actionResults[activeAction]
    : "";

  function selectText() {
    setIsSelected(true);
    setActiveAction(null);
    setCopied(false);
    setIsEditing(false);
  }

  function runAction(action) {
    setActiveAction(action);
    setEditedResult(actionResults[action]);
    setCopied(false);
    setIsEditing(false);
  }

  function closePanel() {
    setIsSelected(false);
    setActiveAction(null);
    setCopied(false);
    setIsEditing(false);
  }

  function pasteBack() {
    setText(result);
    closePanel();
  }

  return (
    <div className="demo-window">
      <div className="window-chrome" aria-hidden="true">
        <span />
        <span />
        <span />
        <div className="format-bar">
          <span>Helvetica</span>
          <span>Regular</span>
          <span>14</span>
        </div>
      </div>
      <div className="demo-document">
        <p className="demo-document-label">Notes</p>
        <h3>Travel note</h3>
        <p>Select the sentence below to try PopGuy.</p>
        <button
          type="button"
          className={`selectable-text ${isSelected ? "is-selected" : ""}`}
          aria-label="Select example text"
          onClick={selectText}
        >
          {text}
        </button>

        {!isSelected ? (
          <span className="selection-hint">
            <WandSparkles size={14} aria-hidden="true" />
            Select the sentence
          </span>
        ) : null}

        {isSelected ? (
          <section
            className={`real-popguy-panel ${activeAction ? "has-result" : ""}`}
            aria-label="PopGuy result"
          >
            <div
              className="real-toolbar"
              role="toolbar"
              aria-label="PopGuy actions"
            >
              <img src="/popguy-logo.png" alt="" />
              {actions.map(({ label, icon: Icon, suffix }, index) => (
                <div className="real-action-group" key={label}>
                  {index > 0 ? <span className="real-divider" /> : null}
                  <button
                    type="button"
                    className={activeAction === label ? "is-active" : ""}
                    aria-label={label}
                    title={label}
                    onClick={() => runAction(label)}
                  >
                    <Icon size={15} aria-hidden="true" />
                  </button>
                  {suffix ? <span className="real-language">{suffix}</span> : null}
                </div>
              ))}
              <span className="real-spacer" />
              <button type="button" aria-label="Ignore this app" title="Ignore this app">
                <EyeOff size={15} aria-hidden="true" />
              </button>
              <button type="button" aria-label="Settings" title="Settings">
                <Settings size={15} aria-hidden="true" />
              </button>
            </div>

            {activeAction ? (
              <div className="real-result" aria-live="polite">
                {isEditing ? (
                  <textarea
                    aria-label="Edit result"
                    value={editedResult}
                    onChange={(event) => setEditedResult(event.target.value)}
                  />
                ) : (
                  <p>{result}</p>
                )}
                <div className="real-result-actions">
                  <button
                    type="button"
                    aria-label="Copy"
                    onClick={() => setCopied(true)}
                  >
                    {copied ? <Check size={13} /> : <Copy size={13} />}
                    {copied ? "Copied" : "Copy"}
                  </button>
                  <button
                    type="button"
                    className="paste-button"
                    aria-label="Paste back"
                    onClick={pasteBack}
                  >
                    <span className="paste-symbol">↶</span>
                    Paste back
                  </button>
                  <button
                    type="button"
                    aria-label={isEditing ? "Done" : "Edit"}
                    onClick={() => setIsEditing((value) => !value)}
                  >
                    {isEditing ? <Check size={13} /> : <Pencil size={13} />}
                    {isEditing ? "Done" : "Edit"}
                  </button>
                  <button type="button" aria-label="Cancel" onClick={closePanel}>
                    <X size={13} />
                    Cancel
                  </button>
                </div>
              </div>
            ) : null}
          </section>
        ) : null}
      </div>
    </div>
  );
}
