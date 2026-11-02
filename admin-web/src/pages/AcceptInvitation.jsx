import React, { useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { ShieldCheck, KeyRound, Loader2, AlertCircle, CheckCircle2 } from 'lucide-react';
import { adminService } from '../services/adminService';

export default function AcceptInvitation() {
  const location = useLocation();
  const navigate = useNavigate();

  const queryParams = new URLSearchParams(location.search);
  const tokenFromUrl = queryParams.get('token') || '';

  const [token, setToken] = useState(tokenFromUrl);
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!token.trim()) {
      setError('Invitation token is missing or invalid.');
      return;
    }
    if (password.length < 8) {
      setError('Password must be at least 8 characters long.');
      return;
    }
    if (password !== confirmPassword) {
      setError('Passwords do not match.');
      return;
    }

    setLoading(true);
    setError('');
    try {
      await adminService.acceptInvite(token.trim(), password);
      setSuccess(true);
    } catch (err) {
      console.error('Failed to accept invitation:', err);
      const detail = err.response?.data?.detail || 'Invalid or expired invitation token.';
      setError(detail);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-surface-bg flex flex-col justify-center py-12 sm:px-6 lg:px-8">
      <div className="sm:mx-auto sm:w-full sm:max-w-md text-center">
        <div className="w-12 h-12 rounded-xl bg-forest mx-auto flex items-center justify-center text-lime-accent shadow-md mb-4 border border-lime-accent/20">
          <ShieldCheck className="w-7 h-7" />
        </div>
        <h2 className="text-2xl font-bold tracking-tight text-text-primary">
          Administrator Onboarding
        </h2>
        <p className="mt-1 text-xs text-text-secondary">
          Activate your KisanRider Administrator account
        </p>
      </div>

      <div className="mt-8 sm:mx-auto sm:w-full sm:max-w-md">
        <div className="bg-white py-8 px-6 shadow-sm border border-surface-border rounded-xl sm:px-10">
          {success ? (
            <div className="text-center space-y-4">
              <CheckCircle2 className="w-12 h-12 text-emerald-600 mx-auto" />
              <h3 className="text-base font-bold text-text-primary">
                Account Activated Successfully!
              </h3>
              <p className="text-xs text-text-secondary leading-relaxed">
                Your administrative password has been securely hashed and stored. You may now log
                in to the administrative dashboard.
              </p>
              <div className="pt-2">
                <Link
                  to="/login"
                  className="w-full inline-block py-2.5 px-4 rounded-lg text-xs font-semibold uppercase tracking-wider text-white bg-forest hover:bg-forest-light transition-colors text-center shadow-xs"
                >
                  Proceed to Login
                </Link>
              </div>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              {error && (
                <div className="p-3 rounded-lg bg-rose-50 border border-rose-200 text-xs text-rose-900 flex items-center space-x-2">
                  <AlertCircle className="w-4 h-4 shrink-0 text-rose-700" />
                  <span>{error}</span>
                </div>
              )}

              <div>
                <label className="block text-xs font-semibold text-text-primary uppercase tracking-wider mb-1">
                  Invitation Token <span className="text-rose-600">*</span>
                </label>
                <input
                  type="text"
                  required
                  value={token}
                  onChange={(e) => setToken(e.target.value)}
                  placeholder="Paste invitation token"
                  className="w-full text-xs font-mono rounded-lg border border-surface-border px-3.5 py-2.5 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-text-primary uppercase tracking-wider mb-1">
                  Create Admin Password (min 8 chars) <span className="text-rose-600">*</span>
                </label>
                <input
                  type="password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••••••"
                  className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-text-primary uppercase tracking-wider mb-1">
                  Confirm Password <span className="text-rose-600">*</span>
                </label>
                <input
                  type="password"
                  required
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  placeholder="••••••••••••"
                  className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
                />
              </div>

              <button
                type="submit"
                disabled={loading}
                className="w-full py-2.5 px-4 rounded-lg text-xs font-semibold uppercase tracking-wider text-white bg-forest hover:bg-forest-light focus:outline-none transition-colors shadow-xs flex items-center justify-center space-x-2 disabled:opacity-70 mt-2"
              >
                {loading && <Loader2 className="w-4 h-4 animate-spin text-lime-accent" />}
                <span>{loading ? 'Activating Account...' : 'Set Password & Activate'}</span>
              </button>

              <div className="pt-2 text-center">
                <Link to="/login" className="text-xs text-forest hover:underline font-medium">
                  Already activated? Go to Sign In
                </Link>
              </div>
            </form>
          )}
        </div>
      </div>
    </div>
  );
}
