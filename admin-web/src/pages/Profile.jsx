import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  KeyRound,
  LogOut,
  CheckCircle2,
  AlertCircle,
  Loader2,
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { adminService } from '../services/adminService';
import Badge from '../components/common/Badge';

export default function Profile() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();

  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');

  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState('');
  const [error, setError] = useState('');

  const handlePasswordChange = async (e) => {
    e.preventDefault();
    if (!currentPassword || !newPassword || !confirmPassword) {
      setError('All password fields are required.');
      return;
    }
    if (newPassword.length < 8) {
      setError('New password must be at least 8 characters long.');
      return;
    }
    if (newPassword !== confirmPassword) {
      setError('New password and confirmation do not match.');
      return;
    }

    setLoading(true);
    setError('');
    setSuccess('');
    try {
      await adminService.changePassword(currentPassword, newPassword);
      setSuccess('Your administrative password has been updated successfully.');
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      setTimeout(() => setSuccess(''), 5000);
    } catch (err) {
      console.error('Failed to change password:', err);
      const detail = err.response?.data?.detail || 'Failed to update password. Verify current password.';
      setError(detail);
    } finally {
      setLoading(false);
    }
  };

  const handleLogout = () => {
    logout();
    navigate('/login');
  };

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Account Info Surface */}
      <div className="bg-white rounded-xl border border-surface-border p-6 shadow-xs">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="flex items-center space-x-4">
            <div className="w-14 h-14 rounded-full bg-forest text-lime-accent flex items-center justify-center text-xl font-bold border border-lime-accent/30 shadow-xs">
              {user?.full_name ? user.full_name.charAt(0).toUpperCase() : 'A'}
            </div>
            <div>
              <h2 className="text-lg font-bold text-text-primary tracking-tight">{user?.full_name || 'Administrator'}</h2>
              <p className="text-xs text-text-secondary mt-0.5">{user?.email || 'admin@kisanrider.in'}</p>
              <div className="flex items-center space-x-2 mt-2.5">
                <span className="inline-flex items-center text-[11px] font-semibold px-2.5 py-0.5 rounded-full bg-lime-subtle text-forest border border-lime-200">
                  {user?.role || 'ADMIN'}
                </span>
                <Badge status={user?.is_active ? 'ACTIVE' : 'SUSPENDED'} />
              </div>
            </div>
          </div>

          <button
            onClick={handleLogout}
            className="inline-flex items-center space-x-2 px-4 py-2 rounded-lg text-xs font-semibold text-rose-700 bg-rose-50 hover:bg-rose-100 border border-rose-200 transition-colors shadow-xs self-start sm:self-auto"
          >
            <LogOut className="w-4 h-4" />
            <span>End Session</span>
          </button>
        </div>
      </div>

      {/* Password Management Form */}
      <div className="bg-white rounded-xl border border-surface-border p-6 shadow-xs">
        <div className="flex items-center space-x-3 pb-4 mb-5 border-b border-surface-border">
          <div className="p-2 rounded-lg bg-surface-subtle text-forest">
            <KeyRound className="w-5 h-5" />
          </div>
          <div>
            <h3 className="text-sm font-bold text-text-primary tracking-tight">Change Password</h3>
            <p className="text-xs text-text-secondary mt-0.5">Update your admin authentication credentials securely</p>
          </div>
        </div>

        {success && (
          <div className="mb-5 p-3.5 rounded-xl bg-emerald-50 border border-emerald-200/80 text-xs text-emerald-900 flex items-center space-x-2.5">
            <CheckCircle2 className="w-4 h-4 text-emerald-600 shrink-0" />
            <span>{success}</span>
          </div>
        )}

        {error && (
          <div className="mb-5 p-3.5 rounded-xl bg-rose-50 border border-rose-200/80 text-xs text-rose-900 flex items-center space-x-2.5">
            <AlertCircle className="w-4 h-4 text-rose-600 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        <form onSubmit={handlePasswordChange} className="space-y-4 max-w-lg">
          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1.5">
              Current Password <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1.5">
              New Password (min 8 characters) <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1.5">
              Confirm New Password <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
            />
          </div>

          <div className="pt-2">
            <button
              type="submit"
              disabled={loading}
              className="px-4 py-2 rounded-lg text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-all shadow-xs flex items-center space-x-2 disabled:opacity-70"
            >
              {loading && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
              <span>{loading ? 'Updating Password...' : 'Update Password'}</span>
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
