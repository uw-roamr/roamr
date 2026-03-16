import styles from './Footer.module.css';

export function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={styles.container}>
        <p className={styles.text}>
          WASM Hub - Part of the ROAMR Robotics Project
        </p>
        <p className={styles.subtext}>
          Share WebAssembly modules across platforms
        </p>
      </div>
    </footer>
  );
}
