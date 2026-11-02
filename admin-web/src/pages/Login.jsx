import React, { useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { ShieldCheck, Eye, EyeOff, Loader2, AlertCircle } from 'lucide-react';
import { useAuth } from '../context/AuthContext';

export default function Login() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState(() => localStorage.getItem('kisanrider_remember_email') || '');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(() => !!localStorage.getItem('kisanrider_remember_email'));
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const isExpired = new URLSearchParams(location.search).get('expired');

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!email || !password) {
      setError('Please provide both email and password.');
      return;
    }

    setError('');
    setLoading(true);

    try {
      await login(email, password);
      if (rememberMe) {
        localStorage.setItem('kisanrider_remember_email', email);
      } else {
        localStorage.removeItem('kisanrider_remember_email');
      }
      navigate('/');
    } catch (err) {
      console.error('Login error:', err);
      const detail = err.response?.data?.detail;
      setError(
        typeof detail === 'string'
          ? detail
          : 'Invalid credentials or access denied. Only active administrators may access this portal.'
      );
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
          KisanRider Admin Web
        </h2>
        <p className="mt-1 text-xs text-text-secondary">
          Agricultural Spatial Logistics & Freight Administration
        </p>
      </div>

      <div className="mt-8 sm:mx-auto sm:w-full sm:max-w-md">
        <div className="bg-white py-8 px-6 shadow-sm border border-surface-border rounded-xl sm:px-10">
          {isExpired && !error && (
            <div className="mb-4 p-3 rounded-lg bg-amber-50 border border-amber-200 text-xs text-amber-900 flex items-center space-x-2">
              <AlertCircle className="w-4 h-4 shrink-0 text-amber-700" />
              <span>Your administrative session has expired. Please log in again.</span>
            </div>
          )}

          {error && (
            <div className="mb-4 p-3 rounded-lg bg-rose-50 border border-rose-200 text-xs text-rose-900 flex items-center space-x-2">
              <AlertCircle className="w-4 h-4 shrink-0 text-rose-700" />
              <span>{error}</span>
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-5">
            <div>
              <label className="block text-xs font-semibold text-text-primary uppercase tracking-wider mb-1.5">
                Admin Email Address
              </label>
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="admin@kisanrider.in"
                className="w-full text-sm rounded-lg border border-surface-border px-3.5 py-2.5 focus:outline-none focus:ring-1 focus:ring-forest focus:border-forest text-text-primary placeholder:text-text-muted transition-colors"
              />
            </div>

            <div>
              <label className="block text-xs font-semibold text-text-primary uppercase tracking-wider mb-1.5">
                Password
              </label>
              <div className="relative">
                <input
                  type={showPassword ? 'text' : 'password'}
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••••••"
                  className="w-full text-sm rounded-lg border border-surface-border px-3.5 py-2.5 pr-10 focus:outline-none focus:ring-1 focus:ring-forest focus:border-forest text-text-primary placeholder:text-text-muted transition-colors"
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute inset-y-0 right-0 pr-3 flex items-center text-text-secondary hover:text-text-primary"
                >
                  {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between text-xs">
              <label className="flex items-center space-x-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={rememberMe}
                  onChange={(e) => setRememberMe(e.target.checked)}
                  className="rounded border-surface-border text-forest focus:ring-forest w-3.5 h-3.5"
                />
                <span className="text-text-secondary">Remember email on this machine</span>
              </label>
            </div>

            <button
              type="submit"
              disabled={loading}
              className="w-full py-2.5 px-4 rounded-lg text-xs font-semibold uppercase tracking-wider text-white bg-forest hover:bg-forest-light focus:outline-none focus:ring-2 focus:ring-forest/50 transition-colors shadow-xs flex items-center justify-center space-x-2 disabled:opacity-70 disabled:cursor-not-allowed"
            >
              {loading && <Loader2 className="w-4 h-4 animate-spin text-lime-accent" />}
              <span>{loading ? 'Authenticating...' : 'Sign In to Portal'}</span>
            </button>
          </form>

          <div className="mt-6 pt-5 border-t border-surface-border text-center">
            <p className="text-[11px] text-text-muted leading-relaxed">
              Authorized access only. Public registration is restricted to Farmers and Riders.
              Additional admin accounts require an invitation from an existing administrator.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
