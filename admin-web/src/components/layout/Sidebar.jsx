import React from 'react';
import { NavLink as RouterNavLink, useNavigate as useRouterNavigate } from 'react-router-dom';
import {
  LayoutDashboard,
  Users,
  Truck,
  PackageCheck,
  Navigation,
  Layers,
  CircleDollarSign,
  TrendingUp,
  FileBarChart2,
  ShieldCheck,
  History,
  UserCheck,
  LogOut,
  X,
  Wheat,
} from 'lucide-react';
import { useAuth } from '../../context/AuthContext';

const navigationGroups = [
  {
    group: 'OVERVIEW',
    items: [
      { name: 'Dashboard', path: '/', icon: LayoutDashboard },
    ],
  },
  {
    group: 'USER MANAGEMENT',
    items: [
      { name: 'Farmers', path: '/farmers', icon: Users },
      { name: 'Riders', path: '/riders', icon: Truck },
    ],
  },
  {
    group: 'OPERATIONS',
    items: [
      { name: 'Transport Requests', path: '/transport-requests', icon: PackageCheck },
      { name: 'Trips', path: '/trips', icon: Navigation },
      { name: 'Farmer Pools', path: '/pools', icon: Layers },
    ],
  },
  {
    group: 'FINANCIAL MANAGEMENT',
    items: [
      { name: 'Settlements', path: '/settlements', icon: CircleDollarSign },
    ],
  },
  {
    group: 'MARKET',
    items: [
      { name: 'Mandi Prices', path: '/mandi-prices', icon: TrendingUp },
    ],
  },
  {
    group: 'ANALYTICS',
    items: [
      { name: 'Reports & Analytics', path: '/reports', icon: FileBarChart2 },
    ],
  },
  {
    group: 'ADMINISTRATION',
    items: [
      { name: 'Admin Management', path: '/admin-management', icon: ShieldCheck },
      { name: 'Activity Logs', path: '/activity-logs', icon: History },
    ],
  },
  {
    group: 'ACCOUNT',
    items: [
      { name: 'Admin Profile', path: '/profile', icon: UserCheck },
    ],
  },
];

export default function Sidebar({ isOpen, onClose }) {
  const { logout, user } = useAuth();
  const navigate = useRouterNavigate();

  const handleLogout = () => {
    logout();
    navigate('/login');
  };

  return (
    <>
      {/* Mobile overlay */}
      {isOpen && (
        <div
          className="fixed inset-0 z-40 bg-black/50 md:hidden backdrop-blur-xs"
          onClick={onClose}
        />
      )}

      {/* Sidebar container */}
      <aside
        className={`fixed top-0 bottom-0 left-0 z-40 w-64 bg-forest text-white flex flex-col transition-transform duration-200 ease-in-out md:translate-x-0 border-r border-forest-dark/40 ${
          isOpen ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        {/* Brand header */}
        <div className="h-16 flex items-center justify-between px-6 border-b border-white/10">
          <div className="flex items-center space-x-2.5">
            <div className="w-8 h-8 rounded bg-lime-accent flex items-center justify-center text-forest font-black tracking-tighter">
              KR
            </div>
            <div>
              <span className="font-bold text-base tracking-tight text-white block leading-none">
                KisanRider
              </span>
              <span className="text-[10px] font-semibold text-lime-accent uppercase tracking-widest block mt-0.5">
                Admin Web
              </span>
            </div>
          </div>
          <button
            onClick={onClose}
            className="md:hidden text-gray-400 hover:text-white p-1 rounded"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Scrollable Navigation */}
        <div className="flex-1 overflow-y-auto px-4 py-5 space-y-6">
          {navigationGroups.map((grp, gIdx) => (
            <div key={gIdx} className="space-y-1">
              <span className="text-[10px] font-bold text-gray-400/80 uppercase tracking-wider px-3 block mb-1.5">
                {grp.group}
              </span>
              {grp.items.map((item, iIdx) => {
                const Icon = item.icon;
                return (
                  <RouterNavLink
                    key={iIdx}
                    to={item.path}
                    end={item.path === '/'}
                    onClick={() => {
                      if (window.innerWidth < 768) onClose();
                    }}
                    className={({ isActive }) =>
                      `flex items-center space-x-3 px-3 py-2 rounded-md text-xs font-medium transition-colors ${
                        isActive
                          ? 'bg-lime-accent text-forest font-semibold shadow-xs'
                          : 'text-gray-300 hover:bg-forest-light hover:text-white'
                      }`
                    }
                  >
                    <Icon className="w-4 h-4 shrink-0" />
                    <span className="truncate">{item.name}</span>
                  </RouterNavLink>
                );
              })}
            </div>
          ))}

          {/* Quick Logout Button in nav */}
          <div className="pt-2 border-t border-white/10">
            <button
              onClick={handleLogout}
              className="w-full flex items-center space-x-3 px-3 py-2 rounded-md text-xs font-medium text-rose-300 hover:bg-rose-950/40 hover:text-rose-200 transition-colors"
            >
              <LogOut className="w-4 h-4 shrink-0" />
              <span>Log out</span>
            </button>
          </div>
        </div>

        {/* Current user badge in bottom footer */}
        <div className="p-4 border-t border-white/10 bg-forest-dark/40 flex items-center space-x-3">
          <div className="w-8 h-8 rounded-full bg-forest-light border border-lime-accent/40 flex items-center justify-center text-xs font-bold text-lime-accent">
            {user?.full_name ? user.full_name.charAt(0).toUpperCase() : 'A'}
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-xs font-semibold text-white truncate">
              {user?.full_name || 'Administrator'}
            </p>
            <p className="text-[11px] text-gray-400 truncate">
              {user?.email || 'admin@kisanrider.in'}
            </p>
          </div>
        </div>
      </aside>
    </>
  );
}
