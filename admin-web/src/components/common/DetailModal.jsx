import React from 'react';
import { X } from 'lucide-react';

export default function DetailModal({ isOpen, onClose, title, subtitle, children, maxWidth = 'max-w-2xl' }) {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-black/40 backdrop-blur-xs flex items-center justify-center p-4">
      <div
        className={`bg-white rounded-lg w-full ${maxWidth} border border-surface-border shadow-xl overflow-hidden flex flex-col max-h-[90vh] animate-in fade-in zoom-in-95 duration-150`}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle">
          <div>
            <h3 className="text-base font-semibold text-text-primary">{title}</h3>
            {subtitle && <p className="text-xs text-text-secondary mt-0.5">{subtitle}</p>}
          </div>
          <button
            onClick={onClose}
            className="text-text-secondary hover:text-text-primary p-1 rounded hover:bg-gray-200 transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Scrollable Content */}
        <div className="p-6 overflow-y-auto space-y-6 text-sm">{children}</div>

        {/* Footer */}
        <div className="px-6 py-3 border-t border-surface-border bg-surface-subtle/50 flex justify-end">
          <button
            onClick={onClose}
            className="px-4 py-2 text-xs font-medium rounded border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors"
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
