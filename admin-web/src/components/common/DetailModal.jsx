import React from 'react';
import { X } from 'lucide-react';

export default function DetailModal({
  isOpen,
  onClose,
  title,
  subtitle,
  children,
  maxWidth = 'max-w-2xl',
}) {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4">
      <div
        className={`bg-white rounded-xl w-full ${maxWidth} border border-surface-border shadow-modal overflow-hidden flex flex-col max-h-[90vh] transition-all animate-in fade-in zoom-in-95 duration-150`}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle/50 shrink-0">
          <div>
            <h3 className="text-base font-bold text-text-primary tracking-tight">{title}</h3>
            {subtitle && <p className="text-xs text-text-secondary mt-0.5">{subtitle}</p>}
          </div>
          <button
            onClick={onClose}
            className="text-text-secondary hover:text-text-primary p-1.5 rounded-lg hover:bg-surface-subtle transition-colors"
            aria-label="Close detail modal"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Scrollable Content */}
        <div className="p-6 overflow-y-auto space-y-6 text-xs">{children}</div>

        {/* Footer */}
        <div className="px-6 py-3.5 border-t border-surface-border bg-surface-subtle/40 flex justify-end shrink-0">
          <button
            onClick={onClose}
            className="px-4 py-2 text-xs font-semibold rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors shadow-xs"
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
