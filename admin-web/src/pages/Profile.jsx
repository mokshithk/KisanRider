import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  UserCheck,
  Shield,
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
      <div className="bg-white rounded-lg border border-surface-border p-6 shadow-xs">
        <div className="flex items-start justify-between">
          <div className="flex items-center space-x-4">
            <div className="w-14 h-14 rounded-full bg-forest text-lime-accent flex items-center justify-center text-xl font-bold border border-lime-accent/30">
              {user?.full_name ? user.full_name.charAt(0).toUpperCase() : 'A'}
            </div>
            <div>
              <h2 className="text-lg font-bold text-text-primary">{user?.full_name || 'Administrator'}</h2>
              <p className="text-xs text-text-secondary">{user?.email || 'admin@kisanrider.in'}</p>
              <div className="flex items-center space-x-2 mt-2">
                <span className="text-xs font-semibold px-2 py-0.5 rounded bg-lime-muted text-forest border border-lime-accent/40">
                  {user?.role || 'ADMIN'}
                </span>
                <Badge status={user?.is_active ? 'ACTIVE' : 'SUSPENDED'} />
              </div>
            </div>
          </div>

          <button
            onClick={handleLogout}
            className="inline-flex items-center space-x-2 px-3.5 py-2 rounded text-xs font-medium text-rose-700 bg-rose-50 hover:bg-rose-100 border border-rose-200 transition-colors"
          >
            <LogOut className="w-4 h-4" />
            <span>End Session</span>
          </button>
        </div>
      </div>

      {/* Password Management Form */}
      <div className="bg-white rounded-lg border border-surface-border p-6 shadow-xs">
        <div className="flex items-center space-x-2.5 pb-4 mb-4 border-b border-surface-border">
          <KeyRound className="w-5 h-5 text-forest" />
          <div>
            <h3 className="text-sm font-bold text-text-primary">Change Password</h3>
            <p className="text-xs text-text-secondary">Update your admin authentication credentials securely</p>
          </div>
        </div>

        {success && (
          <div className="mb-4 p-3 rounded bg-emerald-50 border border-emerald-200 text-xs text-emerald-900 flex items-center space-x-2">
            <CheckCircle2 className="w-4 h-4 text-emerald-600 shrink-0" />
            <span>{success}</span>
          </div>
        )}

        {error && (
          <div className="mb-4 p-3 rounded bg-rose-50 border border-rose-200 text-xs text-rose-900 flex items-center space-x-2">
            <AlertCircle className="w-4 h-4 text-rose-600 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        <form onSubmit={handlePasswordChange} className="space-y-4 max-w-lg">
          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1">
              Current Password <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1">
              New Password (min 8 characters) <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-text-primary mb-1">
              Confirm New Password <span className="text-rose-600">*</span>
            </label>
            <input
              type="password"
              required
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              placeholder="••••••••••••"
              className="w-full text-xs rounded border border-surface-border px-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>

          <div className="pt-2">
            <button
              type="submit"
              disabled={loading}
              className="px-4 py-2 rounded text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-colors shadow-xs flex items-center space-x-2 disabled:opacity-70"
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
