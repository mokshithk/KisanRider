import React, { useState } from 'react';
import { AlertTriangle, X, Loader2 } from 'lucide-react';

export default function ConfirmationModal({
  isOpen,
  onClose,
  onConfirm,
  title,
  actionType = 'danger', // 'danger' | 'warning' | 'primary'
  affectedRecord,
  consequences,
  requireReason = true,
  reasonPlaceholder = 'Please provide a clear reason for this administrative action...',
  confirmText = 'Confirm Action',
  isLoading = false,
}) {
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');

  if (!isOpen) return null;

  const handleConfirm = () => {
    if (requireReason && (!reason || reason.trim().length < 3)) {
      setError('A reason with at least 3 characters is required.');
      return;
    }
    setError('');
    onConfirm(reason);
  };

  const handleClose = () => {
    if (isLoading) return;
    setReason('');
    setError('');
    onClose();
  };

  const isDanger = actionType === 'danger';

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4">
      <div className="bg-white rounded-xl max-w-lg w-full border border-surface-border shadow-modal overflow-hidden transition-all animate-in fade-in zoom-in-95 duration-150">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle/50">
          <div className="flex items-center space-x-2.5">
            <div
              className={`p-2 rounded-lg shrink-0 ${
                isDanger ? 'bg-rose-100 text-rose-700' : 'bg-amber-100 text-amber-700'
              }`}
            >
              <AlertTriangle className="w-5 h-5" />
            </div>
            <h3 className="text-base font-bold text-text-primary tracking-tight">{title}</h3>
          </div>
          <button
            onClick={handleClose}
            disabled={isLoading}
            className="text-text-secondary hover:text-text-primary p-1.5 rounded-lg hover:bg-surface-subtle transition-colors"
            aria-label="Close modal"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Body */}
        <div className="p-6 space-y-4">
          {affectedRecord && (
            <div className="bg-surface-subtle/60 p-3.5 rounded-lg border border-surface-border text-xs">
              <span className="text-text-secondary font-medium">Target Record / Account:</span>
              <p className="font-semibold text-text-primary mt-0.5">{affectedRecord}</p>
            </div>
          )}

          {consequences && (
            <div className="text-xs">
              <span className="font-semibold text-rose-700 block mb-1">Consequences:</span>
              <p className="bg-rose-50 text-rose-900 p-3.5 rounded-lg border border-rose-200/80 leading-relaxed">
                {consequences}
              </p>
            </div>
          )}

          {requireReason && (
            <div>
              <label className="block text-xs font-semibold text-text-primary mb-1.5">
                Administrative Reason <span className="text-rose-600">*</span>
              </label>
              <textarea
                value={reason}
                onChange={(e) => {
                  setReason(e.target.value);
                  if (error) setError('');
                }}
                disabled={isLoading}
                rows={3}
                placeholder={reasonPlaceholder}
                className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest text-text-primary placeholder:text-text-muted transition-all"
              />
              {error && <p className="text-xs text-rose-600 mt-1.5 font-medium">{error}</p>}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-3.5 border-t border-surface-border bg-surface-subtle/40 flex items-center justify-end space-x-3">
          <button
            type="button"
            onClick={handleClose}
            disabled={isLoading}
            className="px-4 py-2 text-xs font-medium rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleConfirm}
            disabled={isLoading}
            className={`inline-flex items-center space-x-2 px-4 py-2 text-xs font-semibold rounded-lg text-white transition-all shadow-xs disabled:opacity-50 ${
              isDanger ? 'bg-rose-600 hover:bg-rose-700' : 'bg-forest hover:bg-forest-light'
            }`}
          >
            {isLoading && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
            <span>{confirmText}</span>
          </button>
        </div>
      </div>
    </div>
  );
}
