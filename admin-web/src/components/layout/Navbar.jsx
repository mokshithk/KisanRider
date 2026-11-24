import React from 'react';
import { Menu, ShieldCheck } from 'lucide-react';
import { useAuth } from '../../context/AuthContext';

export default function Navbar({ onMenuClick, title }) {
  const { user } = useAuth();

  return (
    <header className="h-16 bg-white border-b border-surface-border px-6 flex items-center justify-between sticky top-0 z-30 shadow-xs">
      <div className="flex items-center space-x-3.5">
        <button
          onClick={onMenuClick}
          className="md:hidden text-text-secondary hover:text-text-primary p-2 rounded-lg hover:bg-surface-subtle transition-colors"
          aria-label="Open sidebar navigation"
        >
          <Menu className="w-5 h-5" />
        </button>
        <div>
          <h1 className="text-lg font-bold text-text-primary tracking-tight">{title}</h1>
        </div>
      </div>

      <div className="flex items-center space-x-4">
        {/* Environment & Live System Indicator */}
        <div className="hidden sm:inline-flex items-center space-x-2 px-3 py-1 rounded-full bg-emerald-50 border border-emerald-200/80 text-xs font-medium text-emerald-800 shadow-xs">
          <span className="w-2 h-2 rounded-full bg-emerald-500 animate-pulse"></span>
          <span>System Live</span>
        </div>

        {/* User Profile Pill */}
        <div className="flex items-center space-x-2.5 pl-3 border-l border-surface-border">
          <div className="w-8 h-8 rounded-full bg-forest text-lime-accent flex items-center justify-center text-xs font-bold shadow-xs">
            {user?.full_name ? user.full_name.charAt(0).toUpperCase() : 'A'}
          </div>
          <div className="hidden md:block text-left">
            <span className="text-xs font-semibold text-text-primary block leading-tight">
              {user?.full_name || 'Administrator'}
            </span>
            <span className="text-[10px] text-text-secondary font-medium tracking-wide">
              ADMIN
            </span>
          </div>
        </div>
      </div>
    </header>
  );
}
