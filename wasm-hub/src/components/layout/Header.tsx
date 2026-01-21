import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../../contexts/AuthContext';
import { logOut } from '../../services/auth';
import { useToast } from '../ui/Toast';
import { Button } from '../ui/Button';
import styles from './Header.module.css';

export function Header() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const { showToast } = useToast();

  const handleLogout = async () => {
    try {
      await logOut();
      showToast('Logged out successfully', 'success');
      navigate('/');
    } catch {
      showToast('Failed to log out', 'error');
    }
  };

  return (
    <header className={styles.header}>
      <div className={styles.container}>
        <Link to="/" className={styles.logo}>
          <span className={styles.logoIcon}>⚙️</span>
          WASM Hub
        </Link>

        <nav className={styles.nav}>
          <Link to="/browse" className={styles.navLink}>
            Browse
          </Link>
          {user ? (
            <>
              <Link to="/dashboard" className={styles.navLink}>
                My Files
              </Link>
              <Link to="/upload" className={styles.navLink}>
                Upload
              </Link>
              <div className={styles.userSection}>
                <span className={styles.userName}>
                  {user.displayName || user.email}
                </span>
                <Button variant="ghost" size="sm" onClick={handleLogout}>
                  Log out
                </Button>
              </div>
            </>
          ) : (
            <div className={styles.authButtons}>
              <Link to="/login">
                <Button variant="ghost" size="sm">
                  Log in
                </Button>
              </Link>
              <Link to="/register">
                <Button size="sm">Sign up</Button>
              </Link>
            </div>
          )}
        </nav>
      </div>
    </header>
  );
}
