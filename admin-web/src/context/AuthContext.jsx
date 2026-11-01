import React, { createContext, useContext, useState, useEffect } from 'react';
import { adminService } from '../services/adminService';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [token, setToken] = useState(() => localStorage.getItem('kisanrider_admin_token'));
  const [user, setUser] = useState(() => {
    const saved = localStorage.getItem('kisanrider_admin_user');
    return saved ? JSON.parse(saved) : null;
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const verifyAuth = async () => {
      const storedToken = localStorage.getItem('kisanrider_admin_token');
      if (storedToken) {
        try {
          const profile = await adminService.getProfile();
          setUser(profile);
          localStorage.setItem('kisanrider_admin_user', JSON.stringify(profile));
        } catch (err) {
          console.error("Auth verification failed:", err);
          logout();
        }
      }
      setLoading(false);
    };

    verifyAuth();
  }, []);

  const login = async (email, password) => {
    const data = await adminService.login(email, password);
    setToken(data.access_token);
    setUser(data.admin);
    localStorage.setItem('kisanrider_admin_token', data.access_token);
    localStorage.setItem('kisanrider_admin_user', JSON.stringify(data.admin));
    return data.admin;
  };

  const logout = () => {
    setToken(null);
    setUser(null);
    localStorage.removeItem('kisanrider_admin_token');
    localStorage.removeItem('kisanrider_admin_user');
  };

  return (
    <AuthContext.Provider
      value={{
        token,
        user,
        isAuthenticated: !!token && !!user,
        loading,
        login,
        logout,
        setUser,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
