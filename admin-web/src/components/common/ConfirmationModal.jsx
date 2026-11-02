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
    <div className="fixed inset-0 z-50 overflow-y-auto bg-black/40 backdrop-blur-xs flex items-center justify-center p-4">
      <div className="bg-white rounded-lg max-w-lg w-full border border-surface-border shadow-xl overflow-hidden transition-all animate-in fade-in zoom-in-95 duration-150">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle">
          <div className="flex items-center space-x-2">
            <div
              className={`p-1.5 rounded-full ${
                isDanger ? 'bg-rose-100 text-rose-700' : 'bg-amber-100 text-amber-700'
              }`}
            >
              <AlertTriangle className="w-5 h-5" />
            </div>
            <h3 className="text-base font-semibold text-text-primary">{title}</h3>
          </div>
          <button
            onClick={handleClose}
            disabled={isLoading}
            className="text-text-secondary hover:text-text-primary p-1 rounded hover:bg-gray-200 transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </div>

        {/* Body */}
        <div className="p-6 space-y-4">
          {affectedRecord && (
            <div className="bg-surface-bg p-3 rounded border border-surface-border text-xs">
              <span className="text-text-secondary font-medium">Target Record / Account:</span>
              <p className="font-semibold text-text-primary mt-0.5">{affectedRecord}</p>
            </div>
          )}

          {consequences && (
            <div className="text-sm text-text-secondary">
              <span className="font-semibold text-rose-700 block mb-1">Consequences:</span>
              <p className="bg-rose-50 text-rose-900 p-3 rounded border border-rose-200 text-xs leading-relaxed">
                {consequences}
              </p>
            </div>
          )}

          {requireReason && (
            <div>
              <label className="block text-xs font-semibold text-text-primary mb-1">
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
                className="w-full text-sm rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest focus:border-forest text-text-primary placeholder:text-text-muted"
              />
              {error && <p className="text-xs text-rose-600 mt-1">{error}</p>}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-end space-x-3 px-6 py-4 border-t border-surface-border bg-surface-subtle">
          <button
            type="button"
            onClick={handleClose}
            disabled={isLoading}
            className="px-4 py-2 text-xs font-medium rounded border border-surface-border text-text-primary bg-white hover:bg-surface-subtle transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleConfirm}
            disabled={isLoading}
            className={`px-4 py-2 text-xs font-medium rounded text-white flex items-center space-x-2 transition-colors ${
              isDanger
                ? 'bg-rose-700 hover:bg-rose-800'
                : 'bg-forest hover:bg-forest-light'
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
