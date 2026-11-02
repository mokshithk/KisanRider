import React, { useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';
import Sidebar from './Sidebar';
import Navbar from './Navbar';

const pageTitles = {
  '/': 'Operational Dashboard',
  '/farmers': 'Farmer Management',
  '/riders': 'Rider Management',
  '/transport-requests': 'Transport Requests',
  '/trips': 'Trips Oversight',
  '/pools': 'Farmer Pool Management',
  '/settlements': 'Financial Settlements',
  '/mandi-prices': 'APMC Mandi Rates',
  '/reports': 'Reports & Analytics',
  '/admin-management': 'Administrator Team',
  '/activity-logs': 'Audit & Activity Logs',
  '/profile': 'Administrator Profile',
};

export default function Layout() {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const location = useLocation();

  const title = pageTitles[location.pathname] || 'Admin Portal';

  return (
    <div className="min-h-screen bg-surface-bg flex">
      {/* Sidebar */}
      <Sidebar isOpen={sidebarOpen} onClose={() => setSidebarOpen(false)} />

      {/* Main Content Area */}
      <div className="flex-1 flex flex-col md:pl-64 min-w-0">
        <Navbar onMenuClick={() => setSidebarOpen(true)} title={title} />
        <main className="flex-1 p-6 max-w-7xl w-full mx-auto">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
