import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './context/AuthContext';
import Layout from './components/layout/Layout';

// Pages
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Farmers from './pages/Farmers';
import Riders from './pages/Riders';
import TransportRequests from './pages/TransportRequests';
import Trips from './pages/Trips';
import Pools from './pages/Pools';
import Settlements from './pages/Settlements';
import MandiPrices from './pages/MandiPrices';
import Reports from './pages/Reports';
import AdminManagement from './pages/AdminManagement';
import ActivityLogs from './pages/ActivityLogs';
import Profile from './pages/Profile';
import AcceptInvitation from './pages/AcceptInvitation';

function ProtectedRoute({ children }) {
  const { isAuthenticated, loading } = useAuth();

  if (loading) {
    return (
      <div className="min-h-screen bg-surface-bg flex items-center justify-center">
        <div className="w-8 h-8 rounded-full border-2 border-forest border-t-transparent animate-spin"></div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace />;
  }

  return children;
}

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          {/* Public Authentication Routes */}
          <Route path="/login" element={<Login />} />
          <Route path="/accept-invitation" element={<AcceptInvitation />} />

          {/* Protected Administrative Routes */}
          <Route
            element={
              <ProtectedRoute>
                <Layout />
              </ProtectedRoute>
            }
          >
            <Route path="/" element={<Dashboard />} />
            <Route path="/farmers" element={<Farmers />} />
            <Route path="/riders" element={<Riders />} />
            <Route path="/transport-requests" element={<TransportRequests />} />
            <Route path="/trips" element={<Trips />} />
            <Route path="/pools" element={<Pools />} />
            <Route path="/settlements" element={<Settlements />} />
            <Route path="/mandi-prices" element={<MandiPrices />} />
            <Route path="/reports" element={<Reports />} />
            <Route path="/admin-management" element={<AdminManagement />} />
            <Route path="/activity-logs" element={<ActivityLogs />} />
            <Route path="/profile" element={<Profile />} />
          </Route>

          {/* Catch-all */}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}
