import { RegisterForm } from '../components/auth';
import styles from './AuthPage.module.css';

export function RegisterPage() {
  return (
    <div className={styles.page}>
      <RegisterForm />
    </div>
  );
}
