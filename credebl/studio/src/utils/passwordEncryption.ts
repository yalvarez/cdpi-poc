export const passwordValueEncryption = async (
  value: string,
): Promise<string> => {
  try {
    const res = await fetch('/api/encrypt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // Send the raw value here; the server route already applies JSON.stringify
      // before AES encryption, and double-stringifying breaks /auth/sessionDetails.
      body: JSON.stringify({ password: value }),
    })
    const responseData = await res.json()
    const encrypted = responseData.data
    return encrypted
  } catch (error) {
    console.error('Failed to fetch session details:', error)
    throw error
  }
}
