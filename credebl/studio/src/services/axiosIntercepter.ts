'use client'

import { JwtPayload, jwtDecode } from 'jwt-decode'
import axios, { AxiosError } from 'axios'
import { generateAccessToken, logoutUser } from '@/utils/session'

import { apiStatusCodes } from '@/config/CommonConstant'
import { store } from '@/lib/store'

interface JwtPaylodCustom extends JwtPayload {
  azp?: string
}

const instance = axios.create({
  baseURL: process.env.NEXT_PUBLIC_BASE_URL,
})

const EcosystemInstance = axios.create({
  baseURL: process.env.PUBLIC_ECOSYSTEM_BASE_URL,
})

export async function logoutAndRedirect(): Promise<void> {
  generateAccessToken()
}

instance.interceptors.request.use(
  async (config) => {
    const { auth } = store.getState()
    if (!auth?.token || !auth?.refreshToken) {
      return config
    }
    const { token } = auth
    try {
      const currentTime = Math.floor(Date.now() / 1000)
      const { refreshToken } = auth
      const client = jwtDecode<JwtPaylodCustom>(refreshToken).azp
      const adminPortalClientId =
        process.env.NEXT_PUBLIC_ADMIN_PORTAL_CLIENT_ID
      const appLauncherEnabled =
        process.env.NEXT_PUBLIC_ENABLE_APP_LAUNCHER?.toLowerCase() === 'true'

      // In the CDPI PoC, the platform admin session can legitimately use the
      // same client id (`adminClient`). Logging out unconditionally here ejects
      // the user right after a successful redirect to /dashboard.
      if (
        appLauncherEnabled &&
        adminPortalClientId &&
        client === adminPortalClientId
      ) {
        await logoutUser()
        return config
      }
      const refreshTokenExp = jwtDecode<JwtPayload>(refreshToken).exp
      const isRefreshTokenExpired = refreshTokenExp
        ? refreshTokenExp - currentTime < 1
        : true
      const { exp: accessExp } = jwtDecode<JwtPayload>(token)
      const isExpired = accessExp ? accessExp - currentTime < 1 : true
      if (isExpired && !isRefreshTokenExpired) {
        await generateAccessToken()
        const newToken = store.getState().auth?.token
        if (newToken) {
          return {
            ...config,
            headers: new axios.AxiosHeaders({
              ...config.headers,
              Authorization: `Bearer ${newToken}`,
            }),
          }
        }
      }
      if (isRefreshTokenExpired) {
        await generateAccessToken()
      }
    } catch (error) {
      console.error('Error decoding token:', error)
    }
    return {
      ...config,
      headers: new axios.AxiosHeaders({
        ...config.headers,
        Authorization: `Bearer ${token}`,
      }),
    }
  },
  async (error) => {
    if (error.response?.status === apiStatusCodes.API_STATUS_UNAUTHORIZED) {
      if (typeof window !== 'undefined') {
        await logoutAndRedirect()
      }
    }
    return Promise.reject(error)
  },
)

// RESPONSE INTERCEPTOR
instance.interceptors.response.use(
  (response) => response,
  async (error: AxiosError) => Promise.reject(error),
)

export { instance, EcosystemInstance }
