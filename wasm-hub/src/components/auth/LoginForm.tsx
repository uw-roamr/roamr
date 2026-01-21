import { useState, FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { signIn, getErrorMessage, AuthError } from '../../services/auth';
import { Button, Input } from '../ui';
import { useToast } from '../ui/Toast';
import styles from './AuthForm.module.css';

export function LoginForm() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const navigate = useNavigate();
  const { showToast } = useToast();

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      await signIn(email, password);
      showToast('Welcome back!', 'success');
      navigate('/dashboard');
    } catch (err) {
      setError(getErrorMessage(err as AuthError));
    } finally {
      setLoading(false);
    }
  };

  return (
    <form className={styles.form} onSubmit={handleSubmit}>
      <h1 className={styles.title}>Welcome Back</h1>
      <p className={styles.subtitle}>Sign in to your WASM Hub account</p>

      {error && <div className={styles.error}>{error}</div>}

      <Input
        type="email"
        label="Email"
        placeholder="you@example.com"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        required
      />

      <Input
        type="password"
        label="Password"
        placeholder="Enter your password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        required
      />

      <Button type="submit" loading={loading} className={styles.submitBtn}>
        Sign In
      </Button>

      <p className={styles.switchText}>
        Don't have an account?{' '}
        <Link to="/register" className={styles.link}>
          Sign up
        </Link>
      </p>
    </form>
  );
}
