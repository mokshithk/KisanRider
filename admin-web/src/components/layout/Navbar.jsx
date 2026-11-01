import React from 'react';
import { Menu, Shield, Bell, CheckCircle2 } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';

export default function Navbar({ onMenuClick, title }) {
  const { user } = useAuth();

  return (
    <header className="h-16 bg-white border-b border-surface-border px-6 flex items-center justify-between sticky top-0 z-30 shadow-xs">
      <div className="flex items-center space-x-4">
        <button
          onClick={onMenuClick}
          className="md:hidden text-text-secondary hover:text-text-primary p-1.5 rounded hover:bg-surface-subtle"
        >
          <Menu className="w-5 h-5" />
        </button>
        <div>
          <h1 className="text-lg font-bold text-text-primary tracking-tight">{title}</h1>
        </div>
      </div>

      <div className="flex items-center space-x-4">
        {/* Environment & Live System Indicator */}
        <div className="hidden sm:flex items-center space-x-1.5 px-2.5 py-1 rounded-full bg-emerald-50 border border-emerald-200 text-[11px] font-medium text-emerald-800">
          <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
          <span>System Live</span>
        </div>

        {/* User Pill */}
        <div className="flex items-center space-x-2 pl-2 border-l border-surface-border">
          <div className="w-7 h-7 rounded-full bg-forest text-lime-accent flex items-center justify-center text-xs font-bold">
            {user?.full_name ? user.full_name.charAt(0).toUpperCase() : 'A'}
          </div>
          <div className="hidden md:block text-left">
            <span className="text-xs font-semibold text-text-primary block leading-none">
              {user?.full_name || 'Admin'}
            </span>
            <span className="text-[10px] text-text-secondary font-medium">ADMIN</span>
          </div>
        </div>
      </div>
    </header>
  );
}
